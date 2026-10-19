package haxe.io;

/**
	Thread-safe haxe.io.FPHelper for HashLink, shadowing the std one via `-cp stubs`.

	The hl std implementation (std/hl/_std/haxe/io/FPHelper.hx) reinterprets
	ints/floats through ONE process-wide 8-byte buffer with no lock (its own
	comment: "this is not thread safe"). MBHaxe deserialises hxsl shaders
	(readDouble) and loads resources on worker threads, so two concurrent
	conversions can read each other's bytes. The MBHaxe Switch port
	(ChanseyIsTheBest/MBHaxe-Switch, stubs/haxe/io/FPHelper.hx) traced corrupted
	shader constants (vec4(pos,1) -> vec4(pos,0.)) to exactly this race.

	hl: same code as std, serialised with a mutex.
	Everything else (incl. macro/eval context, where hl.Bytes does not exist):
	copied verbatim from the generic std/haxe/io/FPHelper.hx arithmetic branch
	of Haxe 4.3.6, so compile-time shader serialisation is byte-identical to
	an unpatched build.

	Belongs upstream as a thread-local helper in Haxe's hl std.
**/
class FPHelper {
	#if (hl && !macro)
	static var helper = new hl.Bytes(8);
	static var lock = new sys.thread.Mutex();

	public static function i32ToFloat(i:Int):Single {
		lock.acquire();
		helper.setI32(0, i);
		var f = helper.getF32(0);
		lock.release();
		return f;
	}

	public static function floatToI32(f:Single):Int {
		lock.acquire();
		helper.setF32(0, f);
		var i = helper.getI32(0);
		lock.release();
		return i;
	}

	public static function i64ToDouble(low:Int, high:Int):Float {
		lock.acquire();
		helper.setI32(0, low);
		helper.setI32(4, high);
		var d = helper.getF64(0);
		lock.release();
		return d;
	}

	public static function doubleToI64(v:Float):Int64 {
		lock.acquire();
		helper.setF64(0, v);
		var low = helper.getI32(0);
		var high = helper.getI32(4);
		lock.release();
		return Int64.make(high, low);
	}
	#else
	static var i64tmp = Int64.ofInt(0);

	static inline var LN2 = 0.6931471805599453; // Math.log(2)

	static inline function _i32ToFloat(i:Int):Float {
		var sign = 1 - ((i >>> 31) << 1);
		var e = (i >> 23) & 0xff;
		if (e == 255)
			return i & 0x7fffff == 0 ? (sign > 0 ? Math.POSITIVE_INFINITY : Math.NEGATIVE_INFINITY) : Math.NaN;
		var m = e == 0 ? (i & 0x7fffff) << 1 : (i & 0x7fffff) | 0x800000;
		return sign * m * Math.pow(2, e - 150);
	}

	static inline function _i64ToDouble(lo:Int, hi:Int):Float {
		var sign = 1 - ((hi >>> 31) << 1);
		var e = (hi >> 20) & 0x7ff;
		if (e == 2047)
			return lo == 0 && (hi & 0xFFFFF) == 0 ? (sign > 0 ? Math.POSITIVE_INFINITY : Math.NEGATIVE_INFINITY) : Math.NaN;
		var m = 2.220446049250313e-16 * ((hi & 0xFFFFF) * 4294967296. + (lo >>> 31) * 2147483648. + (lo & 0x7FFFFFFF));
		m = e == 0 ? m * 2.0 : m + 1.0;
		return sign * m * Math.pow(2, e - 1023);
	}

	static inline function _floatToI32(f:Float):Int {
		if (f == 0)
			return 0;
		var af = f < 0 ? -f : f;
		var exp = Math.floor(Math.log(af) / LN2);
		if (exp > 127) {
			return 0x7F800000;
		} else {
			if (exp <= -127) {
				exp = -127;
				af *= 7.1362384635298e+44; // af * 0.5 * 0x800000 / Math.pow(2, -127)
			} else {
				af = (af / Math.pow(2, exp) - 1.0) * 0x800000;
			}
			return (f < 0 ? 0x80000000 : 0) | ((exp + 127) << 23) | Math.round(af);
		}
	}

	static inline function _doubleToI64(v:Float):Int64@:privateAccess {
		var i64 = i64tmp;
		if (v == 0) {
			i64.set_low(0);
			i64.set_high(0);
		} else if (!Math.isFinite(v)) {
			i64.set_low(0);
			i64.set_high(v > 0 ? 0x7FF00000 : 0xFFF00000);
		} else {
			var av = v < 0 ? -v : v;
			var exp = Math.floor(Math.log(av) / LN2);
			if (exp > 1023) {
				i64.set_low(0xFFFFFFFF);
				i64.set_high(0x7FEFFFFF);
			} else {
				if (exp <= -1023) {
					exp = -1023;
					av = av / 2.2250738585072014e-308;
				} else {
					av = av / Math.pow(2, exp) - 1.0;
				}
				var sig = Math.fround(av * 4503599627370496.); // 2^52
				var sig_l = Std.int(sig);
				var sig_h = Std.int(sig / 4294967296.0);
				i64.set_low(sig_l);
				i64.set_high((v < 0 ? 0x80000000 : 0) | ((exp + 1023) << 20) | sig_h);
			}
		}
		return i64;
	}

	public static function i32ToFloat(i:Int):Float {
		return _i32ToFloat(i);
	}

	public static function floatToI32(f:Float):Int {
		return _floatToI32(f);
	}

	public static function i64ToDouble(low:Int, high:Int):Float {
		return _i64ToDouble(low, high);
	}

	public static function doubleToI64(v:Float):Int64 {
		return _doubleToI64(v);
	}
	#end
}
