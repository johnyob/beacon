import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:nearby_connections/nearby_connections.dart';

import 'bi_map.dart';


typedef OnPayLoadReceived = void Function(String clientName, Uint8List payload);

class MeshClient {

  final ValueChanged<int> _connectedDevicesCallback;

  final Logger LOG  = Logger();
  final Strategy STRATEGY = Strategy.P2P_CLUSTER;

  final String _clientName;

  // A mapping from so-called 'endpointIds' to clientNames (or endpointNames)
  BiMap<String, String> idNameMap;


  MeshClient(this._clientName, this._connectedDevicesCallback) {
    Logger.level = Level.info;
    idNameMap = new ObservableBiMap(this._connectedDevicesCallback);
  }

  // Initializing the permissions and requirements for the device

  Future<bool> _hasPermissions() async {
    return await Nearby().checkLocationPermission() && await Nearby().checkLocationEnabled();
  }

  Future<bool> _requestPermissions() async {
    return await Nearby().askLocationPermission() && await Nearby().enableLocationServices();
  }

  Future<void> initialise() async {
    if (!await _hasPermissions()) {
      if (!await _requestPermissions()) {
        throw "Unable to start mesh client.";
      }
    }
  }

  // Managing the Nearby Protocols

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> start() async {
    await startDiscovery();
    await startAdvertising();
    LOG.i("Services started :)");
  }

  Future<void> stop() async {
    await stopDiscovery();
    await stopAdvertising();
    LOG.i("Services stopped :(");
  }


  // Protocol Specific asynchronous implementations


  // Snake-like (ish) implementation.
  // The head is advertising and discovering.
  // Body parts are advertising (according to google this is more efficiency,
  // discovery leads to thrashing? saw this on SO page, cannot remember which one lol)

  // Let us consider the following arbitrary disconnected graph:
  //
  //    A/D(N1)         A/D(N2)          A/D(N3)
  //
  // Suppose, non-deterministically, node N2 discovers the
  // endpoint N1 (which simply requires N1 to be in mode A)
  // and requests a connection.

  // N2 then transitions to state A (stopDiscovery), yielding the graph
  //
  //  A/D(N1) <----- A(N2)          A/D(N3)
  //
  // Yeilding a chain. This eventually results in something like:
  //
  // A/D(N1) <-- A(N2) <-- A(N3) <-- ... <-- A(N_M)
  //              ^         ^                   ^
  //              |         |                   |
  //              .         .                   .

  // On a partition, we restart the nearby connection (this hopefully should
  // restart the service and start looking for devices), thus attempting to
  // heal the partition

  // Each advertising node has a maximum connection limit of 3 (to ensure
  // stability of the connections while advertising).

  // To ensure DAGs, we have the following total ordering on node names:
  //
  // N1 > N2 > N3 > ... > N_M


  // Protocol Methods

  Future<void> _onDisconnected(String endpointId) async {
    // Due to chain, we have a partition or we've "lost the endpoint", whatever
    // that means. Either way, its bad... very bad! AAAAAAAAAAAAAAA
    LOG.w("Disconnected from an endpoint: $endpointId. Restarting service...");
    idNameMap.remove(endpointId);
    await restart();
  }


  @override
  Future<void> startDiscovery() async {
    try {
      await Nearby().startDiscovery(
        _clientName, STRATEGY,
        onEndpointFound: (endpointId, endpointName, serviceId) async {
          LOG.i("Endpoint found: ${endpointName}");

          // If we've connected to this endpoint, ignore.
          if (idNameMap.containsKey(endpointId)) return;

          // This prevents other nodes attempting to request a connection
          // while we attempt to request a connection
          LOG.i("Stopping advertising...");
          await stopAdvertising();

          LOG.i("Requesting connection ");
          await Nearby().requestConnection(
            _clientName, endpointId,
            onConnectionInitiated: (endpointId, info) async {
              LOG.i("Connection Initiated with ${endpointId}.");
              idNameMap[endpointId] = endpointName;
              Nearby().acceptConnection(
                  endpointId, onPayLoadRecieved: _onPayLoadReceived);
            },
            onConnectionResult: (endpointId, status) async {
              if (status == Status.CONNECTED) {
                // We have successfully connected to an endpoint
                // Thus we need to disable discovery and re-enable advertising
                LOG.i("Connected: ${endpointId}, ${idNameMap[endpointId]}");
                await stopDiscovery();

                // Advertising is restarted below: (degenerate case)
              } else {
                // If we have failed to connect, then remove the endpoint
                // entry
                LOG.w(
                    "Failed to connect: ${endpointId}, ${idNameMap[endpointId]}");
                idNameMap.remove(endpointId);
              }

              // We have failed to connect (or we have connected).
              // Either way, we must enable advertising
              await startAdvertising();
            },
            onDisconnected: _onDisconnected,
          );
        },
        onEndpointLost: _onDisconnected,
      );
    } on PlatformException catch (e) {
      LOG.e("Discovery Error: ${e.toString()}");
    }
  }

  @override
  Future<void> startAdvertising() async {
    try {
      await Nearby().startAdvertising(
          _clientName, STRATEGY,
          onConnectionInitiated: (endpointId, ConnectionInfo info) async {
            LOG.i("Connection Initiated with ${endpointId}.");
            // Perform comparison on info.endpointName to ensure acyclic property
            if (_clientName.compareTo(info.endpointName) > 0) {
              LOG.i("Accepting connection :)");
              // Yay! We have N1 > N2. Accept the connection :)
              idNameMap[endpointId] = info.endpointName;
              Nearby().acceptConnection(
                  endpointId, onPayLoadRecieved: _onPayLoadReceived);
            } else {
              LOG.w("Rejecting connection :(");
              // Noooooo. We cannot connect at this end of the chain :(
              // Hopefully? the device will try to connect at the head :) (who knows...)
              Nearby().rejectConnection(endpointId);
            }
          },
          onConnectionResult: (endpointId, status) async {
            if (status == Status.CONNECTED) {
              // We've successfully connected :)
              LOG.i("Connected: ${endpointId}, ${idNameMap[endpointId]}");
            } else {
              // We failed to connect :(
              // Remove the entry from nodes.
              LOG.w(
                  "Failed to connect: ${endpointId}, ${idNameMap[endpointId]}");
              idNameMap.remove(endpointId);
            }
          },
          onDisconnected: _onDisconnected
      );
    } on PlatformException catch (e) {
      LOG.e("Advertising Error: ${e.toString()}");
    }
  }


  Future<void> stopDiscovery() async {
    await Nearby().stopDiscovery();
  }

  Future<void> stopAdvertising() async {
    await Nearby().stopAdvertising();
  }


  // Payload Methods

  final List<OnPayLoadReceived> _onPayLoadReceivedCallbacks = new List();

  Future<void> _onPayLoadReceived(String endpointId, Payload payload) async {
    if (payload.type == PayloadType.BYTES) {
      for (OnPayLoadReceived callback in _onPayLoadReceivedCallbacks) {
        callback(idNameMap[endpointId], payload.bytes);
      }
    }
  }

  // Payload Callback Register (and Deregister) Methods

  void registerOnPayLoadReceivedCallback(OnPayLoadReceived callback) {
    _onPayLoadReceivedCallbacks.add(callback);
  }

  // TODO: Add remove function for callbacks

  // Payload Sending Methods

  Future<void> sendPayload(String clientName, Uint8List payload) async {
    try {
      await Nearby().sendBytesPayload(idNameMap.inverse(clientName), payload);
    } catch (e) {
      LOG.e("Connection request error: ${e.toString()}");
    }
  }

  //
  // Future<void> broadcastPayload(Uint8List payload) async {
  //   for (String id in _clientIds) await sendPayload(id, payload);
  // }


  List<String> getClientNames() {
    print("client names: ${idNameMap.values}");
    return idNameMap.values.toList();
  }

}

