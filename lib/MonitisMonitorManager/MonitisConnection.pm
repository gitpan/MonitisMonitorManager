package MonitisMonitorManager::MonitisConnection;
use MonitisMonitorManager;
use strict;
require Thread;
use Thread qw(async);
require Thread::Queue;
use threads::shared;
require Monitis;
use Data::Dumper;
use Carp;

# how long to wait between reconnection attempts
# default would be 60 seconds, alright?
use constant MONITIS_API_RETRY => 60;

# use the same constant as in the Perl-SDK
use constant DEBUG => $ENV{MONITIS_DEBUG} || 0;

sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;

	# create the queue which M3 will queue stuff on
	$self->{queue} = Thread::Queue->new();

	# queue condition, will be used also to stop execution
	$self->{queue_condition} = 0;
	share($self->{queue_condition});

	# share this as we will lock it before accessing monitis_api_context
	$self->{monitis_api_context_lock} = 0;
	share($self->{monitis_api_context_lock});

	# status of the connection to monitis
	$self->{monitis_connection} = 0;

	# cache of monitor ids
	$self->{monitor_ids_cache} = MonitisConnection::MonitorIDCache->new();

	# initialize Monitis API
	carp "Initializing Monitis API with secretkey='$self->{secretkey}' and api_key='$self->{apikey}'" if DEBUG;
	$self->{monitis_api_context} = Monitis->new(
		secret_key => $self->{secretkey},
		api_key => $self->{apikey} );

	# main thread in execution
	$self->{main_thread} = threads->create(\&main_loop, $self);

	return $self;
}

# add a monitor
sub add_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $monitor_name = $args->{monitor_name};
	my $monitor_tag = $args->{monitor_tag};
	my $result_params = $args->{result_params};
	my @optional_params = @{$args->{optional_params}};

	print "Adding monitor '$monitor_name'...";
	my $response = $self->{monitis_api_context}->custom_monitors->add(
		name => $monitor_name, tag => $monitor_tag,
		resultParams => $result_params, @optional_params);
	if ($response->{status} eq 'ok') {
		print "OK\n";
	} elsif ($response->{status} eq "monitorNameExists") {
		print "OK (Monitor already exists)\n";
	} else {
		print "FAILED: '$response->{status}'\n";
		carp Dumper($response) if DEBUG;
		# if we can add a monitor - we don't muck around...
		exit(1);
	}
}

# list all monitors
sub list_monitors {
	my $self = shift;

	print "Listing monitors...";
	my @response = $self->{monitis_api_context}->custom_monitors->get();
	print "OK\n";
	return @response;
}

# delete the given monitor id
sub delete_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $monitor_id = $args->{monitor_id};

	print "Deleting monitor with ID '$monitor_id'...";
	my $response = $self->{monitis_api_context}->custom_monitors->delete(monitorId => $monitor_id);
	if ($response->{status} eq 'ok') {
		print "OK\n";
	} else {
		print "FAILED: '$response->{status}'\n";
		carp Dumper($response) if DEBUG;
		# if we can't delete a monitor - we don't muck around...
		exit(1);
	}
}

# main thread loop
sub main_loop {
	my $self = shift;
	do {
		# assume we connected, although we might have not...
		$self->{monitis_connection}  = 1;

		# start handling items
		$self->handle_queued_items();

		# need to quit?
		if(0 == $self->{queue_condition}) {
			# wait for work...
			lock($self->{queue_condition});
			cond_timedwait($self->{queue_condition}, time() + MONITIS_API_RETRY);
		}

		# were we signaled to quit?
	} while(0 == $self->{queue_condition});

	# before we quit - handle items
	$self->handle_queued_items();

	# anything left in queue? - croak!
	if ($self->{queue}->pending() > 0) {
		croak "Left queue with '" . $self->{queue}->pending() ."' pending requests";
	}
	print "MonitisConnection stopped execution.\n";
}

# handles item in queue
sub handle_queued_items {
	my $self = shift;

	while ($self->{queue}->pending() > 0) {
		# are we connected?
		if (0 == $self->{monitis_connection}) {
			return;
		}

		my $queue_item = $self->{queue}->peek();
		print "Reporting: '$queue_item->{results}'\n";
		# handle item and pop it if we succeeded
		$self->update_data_for_monitor(
			agent_name => $queue_item->{agent_name},
			monitor_name => $queue_item->{monitor_name},
			monitor_tag => $queue_item->{monitor_tag},
			results => $queue_item->{results},
			additional_results => $queue_item->{additional_results},
			checktime => $queue_item->{checktime}
		) and $self->{queue}->dequeue();
	}
}

# will signal the main loop to stop
sub stop {
	my $self = shift;
	carp "Stopping execution of MonitisConnection...";

	# lock and signal in a different block
	{
		lock($self->{queue_condition});
		$self->{queue_condition} = 1;
		cond_signal($self->{queue_condition});
	}

	# wait for execution to finish gracefully
	$self->{main_thread}->join();
}

# simply queue a request
sub queue {
	my $self = shift;
	my ($args) = {@_};
	# agent_name does not have to be defined...
	my $agent_name = $args->{agent_name} || "";
	my $monitor_name = $args->{monitor_name};
	my $monitor_tag = $args->{monitor_tag};
	my $checktime = $args->{checktime};
	my $results = $args->{results};
	my $additional_results = $args->{additional_results};

	carp "Queuing item: '$agent_name' => '$monitor_name' => '$results','$additional_results' (TS: '$checktime') (TAG: '$monitor_tag')";

	# queue the item
	$self->{queue}->enqueue(
		MonitisConnection::QueueItem->new(
			agent_name => $agent_name,
			monitor_name => $monitor_name,
			monitor_tag => $monitor_tag,
			checktime => $checktime,
			results => $results,
			additional_results => $additional_results)
	);
	
	lock($self->{queue_condition});
	# signal the loop to process
	cond_signal($self->{queue_condition});
}

# update data for a monitor, calling Monitis API
sub update_data_for_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};
	my $monitor_tag = $args->{monitor_tag};
	my $checktime = $args->{checktime};
	my $results = $args->{results};
	my $additional_results = $args->{additional_results};

	# sanity check of results...
	if ($results eq "" and $additional_results eq "") {
		carp "Result set is empty! did it parse well?"; 
	}

	# we have to obtain the monitor id in order to update results
	# to do this we first need the monitor tag
	my $monitor_id = $self->get_id_of_monitor(
		agent_name => $agent_name,
		monitor_tag => $monitor_tag,
		monitor_name => $monitor_name);
	if(0 == $monitor_id) {
		return 0;
	} else {
		carp "Obtained monitor_id '$monitor_id' from API call" if DEBUG;
	}

	# call Monitis using the api context provided
	carp "Calling API with '$monitor_id' '$checktime' '$results'" if DEBUG;

	print "Updating data for monitor '$monitor_name'...";

	# adding results
	my $retval = 0;
	eval {
		my $response = $self->{monitis_api_context}->custom_monitors->add_results(
			monitorId => $monitor_id, checktime => $checktime,
			results => $results);
		if ($response->{status} eq 'ok') {
			print "OK\n";
			$retval = 1;
		} else {
			print "FAILED: '$response->{status}'\n";
			carp Dumper($response) if DEBUG;
		}
	};
	if ($@) {
		# we assume a connection error...
		carp "Error connecting to Monitis: $@";
		$self->{monitis_connection} = 0;
		return 0;
	}

	# adding additional results
	if ($additional_results ne "") {
		carp "Adding additional results, calling API with '$monitor_id' '$checktime' '$additional_results'" if DEBUG;
		eval {
			my $response = $self->{monitis_api_context}->custom_monitors->add_additional_results(
				monitorId => $monitor_id, checktime => $checktime,
				results => $additional_results);
				if ($response->{status} eq 'ok') {
				print "OK\n";
				$retval = 1;
			} else {
				print "FAILED: '$response->{status}'\n";
				carp Dumper($response) if DEBUG;
			}
		};
		if ($@) {
			# we assume a connection error...
			carp "Error connecting to Monitis: $@";
			$self->{monitis_connection} = 0;
			return 0;
		}
	}

	return $retval;
}

# returns the monitor id with a given tag
sub get_id_of_monitor {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_name = $args->{monitor_name};
	my $monitor_tag = $args->{monitor_tag};

	# go through caching mechanism
	my $monitor_id = $self->{monitor_ids_cache}->retrieve(
		agent_name => $agent_name,
		monitor_tag => $monitor_tag,
		monitor_name => $monitor_name);
	if(0 != $monitor_id) {
		return $monitor_id;
	} else {
		# call Monitis using the api context provided
		my $response;
		eval {
			$response = $self->{monitis_api_context}->custom_monitors->get(
				tag => $monitor_tag);
		};
		if ($@) {
			# we assume a connection error...
			print "Error connecting to Monitis: $@\n";
			$self->{monitis_connection} = 0;
			return 0;
		}
	
		# error?
		eval {
			if (defined($response) and defined($response->{error}) and
					$response->{error} eq 'Invalid api key') {
				# just exit, we don't want any business if the API key is invalid
				carp "Invalid API key";
				exit(1);
			}
		};
	
		# iterate on all of them and compare the name
		my $i = 0;
		while (defined($response->[$i]->{id})) {
			if ($response->[$i]->{name} eq $monitor_name) {
				carp "Monitor tag/name: '$monitor_tag/$monitor_name' -> ID: '$response->[$i]->{id}'" if DEBUG;
				# cache it for next time!
				$monitor_id = $response->[$i]->{id};
				$self->{monitor_ids_cache}->store(
					agent_name => $agent_name,
					monitor_tag =>  $monitor_tag,
					monitor_name =>  $monitor_name,
					monitor_id =>  $monitor_id);
				return $monitor_id;
			}
			$i++;
		}
		# TODO perhaps add this monitor automatically?
		carp "Could not obtain ID for monitor '$monitor_tag'/'$monitor_name'";
		exit(1);
	}
}

########################
### MONITOR ID CACHE ###
########################
# a simple class to represent a monitor id cache
package MonitisConnection::MonitorIDCache;

sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;

	# cache for monitor ids, to access Monitis a bit less
	$self->{cache} = ();

	return $self;
}

sub store {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_tag = $args->{monitor_tag};
	my $monitor_name = $args->{monitor_name};
	my $monitor_id = $args->{monitor_id};
	$self->{cache}{$agent_name . $monitor_tag . $monitor_name} = $monitor_id;
}

sub retrieve {
	my $self = shift;
	my ($args) = {@_};
	my $agent_name = $args->{agent_name};
	my $monitor_tag = $args->{monitor_tag};
	my $monitor_name = $args->{monitor_name};
	if(defined($self->{cache}{$agent_name . $monitor_tag . $monitor_name})) {
		return $self->{cache}{$agent_name . $monitor_tag . $monitor_name};
	} else {
		return 0;
	}
}

##################
### QUEUE ITEM ###
##################
# a simple class to represent a queue item
package MonitisConnection::QueueItem;

sub new {
	my $class = shift;
	my $self = {@_};
	bless $self, $class;
	return $self;
}

1;
