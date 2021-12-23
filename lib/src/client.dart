// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'exception.dart';
import 'utils.dart';

/// A JSON-RPC 2.0 client.
///
/// A client calls methods on a server and handles the server's responses to
/// those method calls. Methods can be called with [call], or with
/// [notif] if no response is expected.
class Client {

  /// The next request id.
  var _id = 0;

  /// The map of request ids to pending requests.
  final _pendingRequests = <int, _Request>{};

  final _subscriptions = <int, Subscription>{};

  final StreamController<dynamic> statusStream = StreamController<dynamic>();

  //final _done = Completer<void>();

  /// Returns a [Future] that completes when the underlying connection is
  /// closed.
  ///
  /// This is the same future that's returned by [listen] and [close]. It may
  /// complete before [close] is called if the remote endpoint closes the
  /// connection.
  //Future get done => _done.future;

  /// Whether the underlying connection is closed.
  ///
  /// Note that this will be `true` before [close] is called if the remote
  /// endpoint closes the connection.
  //bool get isClosed => _done.isCompleted;

  final Uri _uri;

  bool _closed = false;

  //WebSocketChannel _socket;
  StreamChannel<dynamic>? _channel;

  Client(this._uri) {
    _connect();
  }

  void _connect() {
    var ws = WebSocketChannel.connect(_uri);
    var wschannel = ws.cast<String>();
    var channel = jsonDocument.bind(wschannel).transformStream(ignoreFormatExceptions);
    _channel = channel;
    statusStream.add({'status': 'connected'});
    _handleChannel(channel);
  }

  void _handleChannel(final StreamChannel<dynamic> channel) {
    channel.stream.listen(_handleResponse, 
    onError: (error, stackTrace) async {
      statusStream.addError(error, stackTrace);
      await channel.sink.close();
    }, onDone: () async {
        if(_closed) {
          _cleanup();
          return;
        }
        statusStream.add({'status': 'reconnecting'});
        await Future.delayed(Duration(seconds: 2));
        //reconnect here
        _connect();
    }, cancelOnError: true);
  }

  /// Closes the underlying connection.
  void close() {
    if (!_closed) {
      _closed = true;
      _channel?.sink.close();
    }
    return;
  }

  void _cleanup() {
    for (var subscription in _subscriptions.values) {
      subscription.stream.close();
    }
    _subscriptions.clear();

    for (var request in _pendingRequests.values) {
        request.completer.completeError(StateError(
            'The client closed with pending request "${request.method}".'));
    }
    _pendingRequests.clear();
  }

  /// Sends a JSON-RPC 2 request to invoke the given [method].
  ///
  /// If passed, [parameters] is the parameters for the method. This must be
  /// either an [Iterable] (to pass parameters by position) or a [Map] with
  /// [String] keys (to pass parameters by name). Either way, it must be
  /// JSON-serializable.
  ///
  /// If the request succeeds, this returns the response result as a decoded
  /// JSON-serializable object. If it fails, it throws an [RpcException]
  /// describing the failure.
  ///
  /// Throws a [StateError] if the client is closed while the request is in
  /// flight, or if the client is closed when this method is called.
  Future call(String method, [parameters]) {
    var id = _id++;
    _send(method, parameters, id);

    var completer = Completer.sync();
    _pendingRequests[id] = _Request(method, completer, Chain.current());
    return completer.future;
  }

  Subscription subscribe(String method, [parameters]) {
    var id = _id++;
    var subscription = Subscription(this, id, method, parameters);
    return subscription;
  }


  /// Sends a JSON-RPC 2 request to invoke the given [method] without expecting
  /// a response.
  ///
  /// If passed, [parameters] is the parameters for the method. This must be
  /// either an [Iterable] (to pass parameters by position) or a [Map] with
  /// [String] keys (to pass parameters by name). Either way, it must be
  /// JSON-serializable.
  ///
  /// Since this is just a notification to which the server isn't expected to
  /// send a response, it has no return value.
  ///
  /// Throws a [StateError] if the client is closed when this method is called.
  void notif(String method, [parameters]) =>
      _send(method, parameters);

  /// A helper method for [sendRequest] and [sendNotification].
  ///
  /// Sends a request to invoke [method] with [parameters]. If [id] is given,
  /// the request uses that id.
  void _send(String method, parameters, [int? id]) {
    if (parameters is Iterable) parameters = parameters.toList();
    if (parameters is! Map && parameters is! List && parameters != null) {
      throw ArgumentError('Only maps and lists may be used as JSON-RPC '
          'parameters, was "$parameters".');
    }
    if (_closed) throw StateError('The client is closed.');

    var message = <String, dynamic>{'jsonrpc': '2.0', 'method': method};
    if (id != null) message['id'] = id;
    if (parameters != null) message['params'] = parameters;

    _channel?.sink.add(message);
  }

  /// Handles a decoded response from the server.
  void _handleResponse(response) {
    if (response is List) {
      response.forEach(_handleSingleResponse);
    } else {
      _handleSingleResponse(response);
    }
  }

  /// Handles a decoded response from the server after batches have been
  /// resolved.
  void _handleSingleResponse(response) {
    if (!_isResponseValid(response)) return;
    var id = response['id'];
    id = (id is String) ? int.parse(id) : id;

    if (_subscriptions.containsKey(id)) {
      if (response.containsKey('result')) {
        var sub = _subscriptions[id];
        sub?.stream.add(response['result']);
      }
      return;
    }

    var request = _pendingRequests.remove(id)!;
    if (response.containsKey('result')) {
      request.completer.complete(response['result']);
    } else {
      request.completer.completeError(
          RpcException(response['error']['code'], response['error']['message'],
              data: response['error']['data']),
          request.chain);
    }
  }

  /// Determines whether the server's response is valid per the spec.
  bool _isResponseValid(response) {
    if (response is! Map) return false;
    if (response['jsonrpc'] != '2.0') return false;
    var id = response['id'];
    id = (id is String) ? int.parse(id) : id;
    // if (!_pendingRequests.containsKey(id)) return false;
    if (response.containsKey('result')) return true;

    if (!response.containsKey('error')) return false;
    var error = response['error'];
    if (error is! Map) return false;
    if (error['code'] is! int) return false;
    if (error['message'] is! String) return false;
    return true;
  }
}

/// A pending request to the server.
class _Request {
  /// THe method that was sent.
  final String method;

  /// The completer to use to complete the response future.
  final Completer completer;

  /// The stack chain from where the request was made.
  final Chain chain;

  _Request(this.method, this.completer, this.chain);
}


class Subscription {
  
  StreamController stream = StreamController();

  final Client _cli;
  final int _id;
  final String _method;

  Subscription(Client cli, int id, String method, [parameters]) :
    _cli = cli,
    _id = id,
    _method = method
  {
    _cli._send(_method + '_subscribe', parameters, _id);
    _cli._subscriptions[_id] = this;
  }

  void close() {
    _cli._send(_method+'_unsubscribe', null, _id);
    _cli._subscriptions.remove(_id);
  }

}