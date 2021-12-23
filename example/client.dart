// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:json_rpc_2/json_rpc_2.dart';

void main() async {
  var client = Client(Uri.parse('ws://localhost:4321'));

  // This calls the "count" method on the server. A Future is returned that
  // will complete to the value contained in the server's response.
  var count = await client.call('count');
  print('Count is $count');

  // Parameters are passed as a simple Map or, for positional parameters, an
  // Iterable. Make sure they're JSON-serializable!
  var echo = await client.call('echo', {'message': 'hello'});
  print('Echo says "$echo"!');

  // A notification is a way to call a method that tells the server that no
  // result is expected. Its return type is `void`; even if it causes an
  // error, you won't hear back.
  client.notif('count');

  // If the server sends an error response, the returned Future will complete
  // with an RpcException. You can catch this error and inspect its error
  // code, message, and any data that the server sent along with it.
  try {
    await client.call('divide', {'dividend': 2, 'divisor': 0});
  } on RpcException catch (error) {
    print('RPC error ${error.code}: ${error.message}');
  }
}
