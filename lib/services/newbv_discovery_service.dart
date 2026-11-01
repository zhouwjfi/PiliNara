import 'dart:async' show Completer, Timer;
import 'dart:convert' show utf8;
import 'dart:io'
    show
        Platform,
        InternetAddress,
        InternetAddressType,
        NetworkInterface,
        RawDatagramSocket,
        RawSocketEvent,
        HttpClient,
        HttpStatus;
import 'dart:typed_data' show Uint8List;

import 'package:PiliPlus/utils/permission_handler.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart' show DeviceInfoParser;
import 'package:get/get.dart';

/// 局域网 newBV 投屏设备探测：按需扫描，结果缓存，不做定时轮询
class NewBvDiscoverer {
  NewBvDiscoverer._();

  static final instance = NewBvDiscoverer._();

  static const _port = 47823;
  static const _group = '239.255.255.250';
  static const _scanTimeout = Duration(seconds: 5);
  static const _retryInterval = Duration(seconds: 1);

  /// 上一次扫描确认在线的设备，点击投屏时优先复用
  final castDevice = Rxn<DLNADevice>();

  /// 丢弃缓存：设备重启/换 IP 后原地址已失效，下次投屏重新扫描
  void invalidate() {
    castDevice.value = null;
  }

  bool _permissionChecked = false;
  Future<DLNADevice?>? _scanning;

  /// 全量扫描一次：组播 + 广播 + 同网段逐 IP 单播。
  ///
  /// 找到设备立即返回并缓存；[scanTimeout] 内无应答则返回 null 并清空缓存。
  Future<DLNADevice?> scan() {
    final scanning = _scanning;
    if (scanning != null) return scanning;
    final future = _scan();
    _scanning = future;
    future.whenComplete(() {
      _scanning = null;
    });
    return future;
  }

  Future<DLNADevice?> _scan() async {
    await _ensurePermission();
    final completer = Completer<DLNADevice?>();
    RawDatagramSocket? socket;
    Timer? retry;
    Timer? timeout;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram != null) {
          _onResponse(datagram.data, completer);
        }
      });
      void send() {
        final s = socket;
        if (s == null) return;
        s
          ..send(_searchMsg, InternetAddress(_group), _port)
          ..send(_searchMsg, InternetAddress('255.255.255.255'), _port);
        _sweep(s);
      }

      send();
      // 局域网丢包较多，扫描期间每秒重发一次
      retry = Timer.periodic(_retryInterval, (_) => send());
      timeout = Timer(_scanTimeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });
      final device = await completer.future;
      if (device == null) {
        castDevice.value = null;
      }
      return device;
    } catch (e) {
      castDevice.value = null;
      return null;
    } finally {
      retry?.cancel();
      timeout?.cancel();
      socket?.close();
    }
  }

  Future<void> _ensurePermission() async {
    if (_permissionChecked) return;
    _permissionChecked = true;
    if (!Platform.isAndroid) return;
    // Android 17（targetSdk 37）起访问局域网需运行时权限，否则 UDP 收发被拦截
    await Permission.accessLocalNetwork.request();
  }

  Uint8List get _searchMsg => utf8.encode(
    'M-SEARCH * HTTP/1.1\r\n'
    'HOST: $_group:$_port\r\n'
    'MAN: "ssdp:discover"\r\n'
    'MX: 2\r\n'
    'ST: ssdp:all\r\n\r\n',
  );

  /// 部分路由器会丢弃来自无线终端的组播/广播，这里再对同网段逐个单播探测
  Future<void> _sweep(RawDatagramSocket socket) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final parts = address.address.split('.');
          if (parts.length != 4 || address.address.startsWith('127.')) {
            continue;
          }
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
          for (var i = 1; i < 255; i++) {
            socket.send(_searchMsg, InternetAddress('$prefix$i'), _port);
          }
        }
      }
    } catch (_) {
      // 单次探测失败不影响流程
    }
  }

  void _onResponse(Uint8List data, Completer<DLNADevice?> completer) {
    if (completer.isCompleted) return;
    final text = utf8.decode(data, allowMalformed: true);
    if (!text.startsWith('HTTP/1.1 200')) return;
    if (!text.contains('newBV')) return;

    String? location;
    for (final line in text.split('\r\n')) {
      final index = line.indexOf(':');
      if (index <= 0) continue;
      if (line.substring(0, index).trim().toLowerCase() == 'location') {
        location = line.substring(index + 1).trim();
        break;
      }
    }
    if (location != null) {
      _load(location, completer);
    }
  }

  Future<void> _load(
    String location,
    Completer<DLNADevice?> completer,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(Uri.parse(location));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return;
      final body = await response.transform(utf8.decoder).join();
      final info = DeviceInfoParser(body).parse(Uri.parse(location));
      if (!info.friendlyName.startsWith('newBV')) return;
      final device = DLNADevice(info);
      if (castDevice.value?.info.URLBase != info.URLBase) {
        castDevice.value = device;
      }
      if (!completer.isCompleted) completer.complete(device);
    } catch (_) {
      // 设备描述获取失败，等下一轮重试
    } finally {
      client.close(force: true);
    }
  }
}
