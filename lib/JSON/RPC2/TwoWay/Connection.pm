package JSON::RPC2::TwoWay::Connection;

use 5.10.0;
use strict;
use warnings;

our $VERSION = '0.07'; # VERSION

# standard perl
use Carp;
use Data::Dumper;
use Digest::MD5 qw(md5_base64);
use Scalar::Util qw(refaddr weaken);
use Time::HiRes qw();

*mono_time = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }
    ? sub () { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }
    : \&Time::HiRes::time;

# cpan
use JSON::MaybeXS qw();

use constant ERR_REQ    => -32600;

sub new {
	my ($class, %opt) = @_;
	croak 'no rpc?' unless $opt{rpc} and $opt{rpc}->isa('JSON::RPC2::TwoWay');
	#croak 'no stream?' unless $opt->{stream} and $opt->{stream}->can('write');
	croak 'no write?' unless $opt{write} and ref $opt{write} eq 'CODE';
	my $self = {
		calls => {},
		debug => $opt{debug} ? 1 : 0,
		log => ref $opt{debug} eq 'CODE' ? $opt{debug} : sub { say STDERR @_ },
		next_id => 1,
		owner => $opt{owner},
		request => undef,
		rpc => $opt{rpc},
		json => $opt{rpc}->{json},
		state => undef,
		write => $opt{write},
	};
	weaken $self->{owner};
	return bless $self, $class;
}

sub call {
	my ($self, $name, $args, $cb) = @_;
	croak 'no self?' unless $self;
	croak 'args should be a array or hash reference'
		unless ref $args eq 'ARRAY' or ref $args eq 'HASH';
	croak 'no callback?' unless $cb;
	croak 'callback should be a code reference' if ref $cb ne 'CODE';
	my $id = md5_base64(mono_time() . rand . refaddr($args));
	croak 'duplicate call id' if $self->{calls}->{$id};
	my $request = $self->{json}->encode({
		jsonrpc => '2.0',
		method => $name,
		params => $args,
		id  => $id,
	});
	$self->{calls}->{$id} = [ $cb, 0 ]; # not raw
	#$self->{log}->("call: $request") if $self->{debug};
	$self->write($request);
	return;
}

sub callraw {
	my ($self, $request, $cb) = @_;
	croak 'no self?' unless $self;
	croak 'request should be a array or hash reference'
		unless ref $request eq 'HASH';
	croak 'callback should be a code reference' if ref $cb ne 'CODE';
	my $id = md5_base64(mono_time() . rand . refaddr($request));
	croak 'duplicate call id' if $self->{calls}->{$id};
	$request->{jsonrpc} = '2.0';
	$request->{id} = $id;
	$request = $self->{json}->encode($request);
	$self->{calls}->{$id} = [ $cb, 1 ]; # raw
	#$self->{log}->("callraw: $request") if $self->{debug};
	$self->write($request);
	return;
}

sub notify {
	my ($self, $name, $args, $cb) = @_;
	croak 'no self?' unless $self;
	croak 'args should be a array of hash reference'
		unless ref $args eq 'ARRAY' or ref $args eq 'HASH';
	my $request = $self->{json}->encode({
		jsonrpc => '2.0',
		method => $name,
		params => $args,
	});
	#$self->{log}->("notify: $request") if $self->{debug};
	$self->write($request);
	return;
}

sub handle {
	my ($self, $json) = @_;
	my @err = $self->_handle(\$json);
	$self->{rpc}->_error($self, undef, ERR_REQ, 'Invalid Request: ' . $err[0]) if $err[0];
        return @err;
}

sub _handle {
	my ($self, $jsonr) = @_;
	$self->{log}->('    handle: ' . $$jsonr) if $self->{debug};
	local $@;
	my $r = eval { $self->{json}->decode($$jsonr) };
	return "json decode failed: $@" if $@;
	return 'not a json object' if ref $r ne 'HASH';
	return 'expected jsonrpc version 2.0' unless defined $r->{jsonrpc} and $r->{jsonrpc} eq '2.0';
	# id can be null in the error case
	return 'id is not a string or number' if exists $r->{id} and ref $r->{id};
	if (defined $r->{method}) {
		return $self->{rpc}->_handle_request($self, $r);
	} elsif (exists $r->{id} and (exists $r->{result} or defined $r->{error})) {
		return $self->_handle_response($r);
	} else {
		return 'invalid jsonnrpc object';
	}
}

sub _handle_response {
	my ($self, $r) = @_;
	#$self->{log}->('_handle_response: ' . Dumper($r)) if $self->{debug};
	my $id = $r->{id};
	my ($cb, $raw);
	$cb = delete $self->{calls}->{$id} if $id;
	return unless $cb;
	($cb, $raw) = @$cb;
	if (defined $r->{error}) {
		my $e = $r->{error};
		return 'error is not an object' unless ref $e eq 'HASH';
		return 'error code is not a integer' unless defined $e->{code} and $e->{code} =~ /^-?\d+$/;
        	return 'error message is not a string' if ref $e->{message};
        	return 'extra members in error object' if (keys %$e == 3 and !exists $e->{data}) or (keys %$e > 2);
		if ($raw) {
			$cb->($r);
		} else {
			$cb->($e);
		}
	} else {
		if ($raw) {
			$cb->(0, $r);
		} else {
			$cb->(0, $r->{result});
		}
	}
	return;
}

sub write {
	my $self = shift;
	$self->{log}->('    writing: ' . join '', @_) if $self->{debug};
	$self->{write}->(@_);
}

sub owner {
	my $self = shift;
	weaken ($self->{owner} = shift) if (@_);
	return $self->{owner};
}

sub state {
	my $self = shift;
	$self->{state} = shift if (@_);
	return $self->{state};
}


sub close {
	my $self = shift;
	%$self = (); # nuke'm all
}

#sub DESTROY {
#	my $self = shift;
#	$self->{log}->('destroying ' . $self) if $self->{debug};
#}

1;

=encoding utf8

=head1 NAME

JSON::RPC2::TwoWay::Connection - Transport-independent bidirectional JSON-RPC 2.0 connection

=head1 SYNOPSIS

  $rpc = JSON::RPC2::TwoWay->new();
  $rpc->register('ping', \&handle_ping);

  $con = $rpc->newconnection(
    owner => $owner, 
    write => sub { $stream->write(@_) }
  );
  @err = $con->handle($stream->read);
  die $err[-1] if @err;

=head1 DESCRIPTION

L<JSON::RPC2::TwoWay::Connection> is a connection containter for
L<JSON::RPC2::TwoWay>.

=head1 METHODS

=head2 new

$con = JSON::RPC2::TwoWay::Connection->new(option => ...);

Class method that returns a new JSON::RPC2::TwoWay::Connection object.
Use newconnection() on a L<JSON::RPC2::TwoWay> object instead.

Valid arguments are:

=over 4

=item - debug: print debugging to STDERR, or if coderef is given call that with 
the debugging line.

(default false)

=item - owner: 'owner' object of this connection.

When provided this object will be asked for the 'state' of the connection.
Otherwise state will always be 0.

=item - rpc: the L<JSON::RPC2::TwoWay> object to handle incoming method calls

(required)

=item - write: a coderef called for writing

This coderef will be called for all output: both requests and responses.
(required)

=back

=head2 call

$con->call('method', { arg => 'foo' }, $cb);

Calls the remote method indicated in the first argument.

The second argument should either be a arrayref or hashref, depending on
wether the remote method requires positional of by-name arguments.  Pass a
empty reference when there are no arguments.

The third argument is a callback: this callback will
be called with the results of the called method.

Call throws an error in case of missing arguments, otherwise it returns
immediately with no return value.

=head2 callraw

$con->callraw({ method => 'method', params => {..} }, $cb);

Enhances the first argument (which should be a hashref) to a full JSON-RPC
2.0 request object and sends the request.  This allows for manipulating and
extending the actual request.

The third argument is a callback: this callback will
be called with the results of the called method.

Callraw throws an error in case of missing arguments, otherwise it returns
immediately with no return value.

=head3 the result callback

The result callback is called with 1 or 2 arguments.  The first argument is
a protocol-error-flag, it contains a error message when there was some kind
of protocol error like calling a normal method as a notification.

If there are 2 arguments the first one is always false, the second one will
contain the results from the remote method, see "REGISTERED CALLBACK CALLING
CONVENTION" in "L<JSON::RPC2::TwoWay>.  The full response will be passed for
access to any extra fields.

=head2 notify

$con->notify('notify_me', { baz => 'foo' })

Calls the remote method as a notification, i.e.  no response will be
expected. Notify throws an error in case of missing arguments, otherwise it
returns immediately with no return value.

=head2 handle

$con->handle($jsonblob)

Handle the incoming request or response. Requests (if valid) are passed on
to the registered callback for that method. Repsonses (if valid) are passed
on to the callback provided in the call.

Handle returns 0, 1 or 2 values.  If no value is returned there were no
errors during processing.  If 1 value is returned there was a 'fatal' error,
and the value is the error message.  If 2 values are returned there was a
'normal' error, the first value is false, the second value is the error
message.

In case of an error, handle will call the provided write callback with a
appropriate error response to be sent to the other side. The application
using the JSON::RPC2::TwoWay::Connection is advised to close the underlying
connection in case of fatal errors.

=head2 close

$con->close()

Closes the connection. Recommended to be used to avoid memory leaks due to
circular references.

=head2 owner

Getter-setter to allow the application to connect the
JSON::RPC2::TwoWay::Connection to some internal connection concept.

-head2 state

Getter-setter for the connection state. Evaluated by JSON::RPC2::TwoWay
when a method was registered with a state option.

=head1 SEE ALSO

=over

=item *

L<JSON::RPC2::TwoWay>

=item *

L<http://www.jsonrpc.org/specification>: JSON-RPC 2.0 Specification

=back

=head1 ACKNOWLEDGEMENT

This software has been developed with support from L<STRATO|https://www.strato.com/>.
In German: Diese Software wurde mit Unterstützung von L<STRATO|https://www.strato.de/> entwickelt.

=head1 THANKS

=over 4

=item *

'greencoloured' for multiple PRs

=back

=head1 AUTHORS

=over 4

=item *

Wieger Opmeer <wiegerop@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2016-2022 by Wieger Opmeer.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

