package datachannel;

/*
	Offline stand-in for hxDatachannel's RTC (https://github.com/RandomityGuy/hxDatachannel, MIT),
	used by compile-linux-gles.hxml instead of `-lib datachannel`.

	The other files in this directory are hxDatachannel's own platform-neutral
	base classes, unmodified: without their .hl.hx overrides they are inert, so
	no libdatachannel/WebRTC/TLS native code is linked. RTC.hx is the one file
	whose natives sit in the base class, so it is replaced with no-ops.
	`inited` is still set because RTCPeerConnection's constructor checks it.
*/
@:allow(datachannel.RTCPeerConnection)
class RTC {
	static var inited:Bool;

	public static function processEvents():Void {}

	public static function init() {
		inited = true;
	}

	public static function finalize() {
		inited = false;
	}
}
