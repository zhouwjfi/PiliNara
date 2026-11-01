import 'dart:convert' show utf8;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_video.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/services/newbv_discovery_service.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 视频卡片（长按菜单）里的直接投屏入口
class NewBvCast {
  NewBvCast._();

  /// 投屏指定视频，返回是否成功；失败时已弹提示
  static Future<bool> castItem(BaseSimpleVideoItemModel item) {
    final bvid = item.bvid;
    if (bvid == null || bvid.isEmpty) {
      SmartDialog.showToast('该视频不支持投屏');
      return Future.value(false);
    }
    return castBvid(
      bvid: bvid,
      fallbackTitle: item.title,
      fallbackCover: item.cover,
    );
  }

  /// 按 bvid 投屏，[fallbackTitle]/[fallbackCover] 用于详情接口未返回时兜底
  static Future<bool> castBvid({
    required String bvid,
    String? fallbackTitle,
    String? fallbackCover,
  }) async {
    SmartDialog.showLoading();
    // 卡片数据可能缺少 aid/cid，先补全视频信息
    final introRes = await VideoHttp.videoIntro(bvid: bvid);
    if (introRes is! Success<VideoDetailData>) {
      SmartDialog.dismiss();
      introRes.toast();
      return false;
    }
    final detail = introRes.response;
    final cid = detail.cid;
    final aid = detail.aid;
    if (cid == null || aid == null) {
      SmartDialog.dismiss();
      SmartDialog.showToast('无法获取视频信息');
      return false;
    }

    final device = await _resolveDevice();
    if (device == null) {
      SmartDialog.dismiss();
      SmartDialog.showToast('未找到投屏设备');
      return false;
    }

    final playRes = await VideoHttp.tvPlayUrl(
      cid: cid,
      objectId: aid,
      playurlType: 1,
    );
    SmartDialog.dismiss();
    if (playRes is! Success<PlayUrlModel>) {
      playRes.toast();
      return false;
    }
    final first = playRes.response.durl?.firstOrNull;
    if (first == null || first.playUrls.isEmpty) {
      SmartDialog.showToast('不支持投屏');
      return false;
    }

    try {
      return await _send(
        device,
        buildCastSoap(
          url: VideoUtils.getCdnUrl(first.playUrls),
          title: detail.title ?? fallbackTitle ?? '',
          aid: aid,
          bvid: bvid,
          cid: cid,
          epid: 0,
          sid: detail.seasonId ?? 0,
          cover: detail.pic ?? fallbackCover ?? '',
        ),
      );
    } catch (_) {
      SmartDialog.showToast('投屏失败');
      return false;
    }
  }

  /// 投屏直播间：接收端按 roomId 打开自带直播播放器，保留画质/弹幕等完整能力
  static Future<bool> castLive({
    required int roomId,
    String? fallbackTitle,
    String? fallbackCover,
  }) async {
    SmartDialog.showLoading();
    final device = await _resolveDevice();
    if (device == null) {
      SmartDialog.dismiss();
      SmartDialog.showToast('未找到投屏设备');
      return false;
    }
    SmartDialog.dismiss();
    try {
      return await _send(
        device,
        buildLiveCastSoap(
          url: 'https://live.bilibili.com/$roomId',
          roomId: roomId,
          title: fallbackTitle ?? '',
          cover: fallbackCover ?? '',
        ),
      );
    } catch (_) {
      SmartDialog.showToast('投屏失败');
      return false;
    }
  }

  /// 发送投屏指令；设备缓存失效（重启/换 IP/端口变化）时重新扫描一次再试
  static Future<bool> _send(DLNADevice device, String soap) async {
    final payload = utf8.encode(soap);
    try {
      await device.request('SetAVTransportURI', payload);
      await device.play();
      return true;
    } catch (_) {
      NewBvDiscoverer.instance.invalidate();
      SmartDialog.showLoading();
      final fresh = await NewBvDiscoverer.instance.scan();
      SmartDialog.dismiss();
      if (fresh == null) {
        SmartDialog.showToast('未找到投屏设备');
        return false;
      }
      try {
        await fresh.request('SetAVTransportURI', payload);
        await fresh.play();
        return true;
      } catch (_) {
        SmartDialog.showToast('投屏失败');
        return false;
      }
    }
  }

  /// 优先复用已确认的设备，否则现场扫描一次
  static Future<DLNADevice?> _resolveDevice() async {
    final discoverer = NewBvDiscoverer.instance;
    final cached = discoverer.castDevice.value;
    if (cached != null) return cached;
    return discoverer.scan();
  }
}

String escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 直播投屏元数据：带上 roomId，接收端直接打开直播间播放器
String buildLiveCastSoap({
  required String url,
  required int roomId,
  required String title,
  required String cover,
}) {
  final metadata =
      '''<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:pili="urn:pilinara:cast:1">
  <item id="pili-cast" parentID="0" restricted="0">
    <dc:title>${escapeXml(title)}</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*">${escapeXml(url)}</res>
    <pili:live>$roomId</pili:live>
    <pili:cover>${escapeXml(cover)}</pili:cover>
  </item>
</DIDL-Lite>''';
  return '''<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>${escapeXml(url)}</CurrentURI>
      <CurrentURIMetaData>${escapeXml(metadata)}</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''';
}

/// 投屏时附带视频标识，接收端可据此加载完整播放能力（画质/弹幕/字幕等）
String buildCastSoap({
  required String url,
  required String title,
  required int aid,
  required String bvid,
  required int cid,
  required int epid,
  required int sid,
  required String cover,
}) {
  final metadata =
      '''<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:pili="urn:pilinara:cast:1">
  <item id="pili-cast" parentID="0" restricted="0">
    <dc:title>${escapeXml(title)}</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:*">${escapeXml(url)}</res>
    <pili:aid>$aid</pili:aid>
    <pili:bvid>${escapeXml(bvid)}</pili:bvid>
    <pili:cid>$cid</pili:cid>
    <pili:epid>$epid</pili:epid>
    <pili:sid>$sid</pili:sid>
    <pili:cover>${escapeXml(cover)}</pili:cover>
  </item>
</DIDL-Lite>''';
  return '''<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>${escapeXml(url)}</CurrentURI>
      <CurrentURIMetaData>${escapeXml(metadata)}</CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>''';
}
