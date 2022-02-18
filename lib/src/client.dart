// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:developer';

import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'exception.dart';
import 'utils.dart';

///status of the client
enum Status {
  /// discontected or not connected
  disconnected,

  ///connected to server
  connected,

  ///alread close by close or server
  closed,

  ///automatic reconnection to server
  reconnecting,

  ///connecting by connect() method
  connecting,
}

/// A JSON-RPC 2.0 client.
///
/// A client calls methods on a server and handles the server's responses to
/// those method calls. Methods can be called with [call], or with
/// [notif] if no response is expected.
class Client {
  final _idGen = const Uuid();

  /// The map of request ids to pending requests.
  final _pendingRequests = <String, _Request>{};

  final _pendingMessages = [];

  final _subscriptions = <String, Subscription>{};

  final _statusController = StreamController<Status>();

  /// Stream status for status update
  Stream<Status> get statusStream => _statusController.stream;

  bool _closed = false;

  StreamChannel<dynamic>? _channel;

  final Uri uri;
  final Duration? reconnectInternal;
  final Duration? connectTimeout;

  Client(this.uri, {this.reconnectInternal, this.connectTimeout});

  void connect() {
    _closed = false;
    _connect();
  }

  void _connect() {
    final ws = WebSocketChannel.connect(uri, connectTimeout: connectTimeout);
    ws.ready.then((_) {
      final wschannel = ws.cast<String>();
      final channel =
          jsonDocument.bind(wschannel).transformStream(ignoreFormatExceptions);
      _handleChannel(channel);
    }, onError: (err) {
      print('connect err $err');
      _reconnect();
    });
  }

  void _reconnect() {
    if (reconnectInternal != null && !_closed) {
      _statusController.add(Status.reconnecting);
      Future.delayed(reconnectInternal!).then((_) => _connect());
    } else {
      _cleanup();
      _statusController.add(Status.disconnected);
    }
  }

  void _handleChannel(StreamChannel channel) {
    _channel = channel;

    //resubscribe all
    for (var subscription in _subscriptions.values) {
      subscription.subscribe();
    }
    for (var msg in _pendingMessages) {
      log('send pending $msg');
      _channel?.sink.add(msg);
    }
    _pendingMessages.clear();

    channel.stream.listen(_handleData, onDone: () {
      channel.sink.close();
      _channel = null;
      _reconnect();
    }, onError: (error, stackTrace) {
      _statusController.addError(error, stackTrace);
    });
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _cleanup();
    _channel?.sink.close();
    _channel = null;
  }

  void _cleanup() {
    for (var subscription in _subscriptions.values) {
      subscription.close();
    }
    _subscriptions.clear();
    _pendingMessages.clear();
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
    var id = _idGen.v4();
    _send(method, parameters, id);
    var completer = Completer.sync();
    _pendingRequests[id] = _Request(method, completer, Chain.current());
    return completer.future;
  }

  Subscription subscribe(String method, [parameters]) {
    final sub = Subscription(this, method, parameters);
    sub.subscribe();
    return sub;
  }

  /// A helper method for [sendRequest] and [sendNotification].
  ///
  /// Sends a request to invoke [method] with [parameters]. If [id] is given,
  /// the request uses that id.
  void _send(String method, parameters, [String? id]) {
    if (parameters is Iterable) parameters = parameters.toList();
    if (parameters is! Map && parameters is! List && parameters != null) {
      throw ArgumentError('Only maps and lists may be used as JSON-RPC '
          'parameters, was "$parameters".');
    }
    var message = <String, dynamic>{'jsonrpc': '2.0', 'method': method};
    if (id != null) message['id'] = id;
    if (parameters != null) message['params'] = parameters;

    if (_channel == null) {
      _pendingMessages.add(message);
    } else {
      log('send $message');
      _channel?.sink.add(message);
    }
  }

  /// Handles a decoded response from the server.
  void _handleData(response) {
    log('_handleResponse $response');
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

    if (response.containsKey('params')) {
      final params = response['params'] as Map;
      if (params.containsKey('subscription')) {
        final subId = params['subscription'] as String;
        final sub = _subscriptions[subId];
        sub?._controller.add(params['result']);
      }
      return;
    }

    var id = response['id'];
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
    // var id = response['id'];
    // if (!_pendingRequests.containsKey(id)) return false;
    if (response.containsKey('result')) return true; //for callback
    if (response.containsKey('params')) return true; //for subscription

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
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final Client _cli;
  final String _method;
  final Object? _parameters;

  String? _subId;

  Stream<dynamic> get stream => _controller.stream;

  Subscription(this._cli, this._method, this._parameters);

  void subscribe() {
    _cli.call(_method + '_subscribe', _parameters).then((rst) {
      _subId = rst as String; //return rst is subscription id
      _cli._subscriptions[rst] = this;
    });
  }

  void unsubscribe() {
    if (_subId != null) {
      _cli.call(_method + '_unsubscribe', [_subId]).then((rst) {
        _cli._subscriptions.remove(_subId);
      });
    }
  }

  void close() {
    _controller.close();
  }
}
