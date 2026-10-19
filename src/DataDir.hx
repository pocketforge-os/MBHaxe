package src;

import haxe.io.Path;

/**
	Where the game data lives and where heaps' resource converter caches its output (HashLink
	desktop builds).

	- MBHAXE_DATA_DIR: the data directory, used instead of data/ next to the executable. It must be
	  a real directory called "data" (resource paths are "data/..." relative to its parent), not a
	  symlink: heaps strips the base directory prefix from real paths, so a symlinked tree loads
	  nothing.
	- MBHAXE_CACHE_DIR: the converter cache, used instead of data/tmp/.

	With both unset the game behaves as upstream: data/ next to the executable, cache in data/tmp/.
	Once either is set (and always in the -D handheld build) the data directory is checked at start
	(missing or a symlink: message on stderr, exit status 2), and if data/tmp/ cannot be written the
	cache moves to $XDG_CACHE_HOME/mbhaxe/converted (default ~/.cache), so a read-only data
	directory works.
**/
class DataDir {
	public static inline var DATA_ENV = "MBHAXE_DATA_DIR";
	public static inline var CACHE_ENV = "MBHAXE_CACHE_DIR";

	static function env(name:String):Null<String> {
		var v = Sys.getEnv(name);
		return v == null || v == "" ? null : v;
	}

	static function strip(p:String):String {
		p = Path.normalize(p);
		return p == "/" ? p : Path.removeTrailingSlashes(p);
	}

	/** MBHAXE_DATA_DIR as an absolute path (symlinks not resolved), or null when unset. */
	public static function configured():Null<String> {
		var d = env(DATA_ENV);
		return d == null ? null : strip(sys.FileSystem.absolutePath(d));
	}

	static function checked():Bool {
		#if handheld
		return true;
		#else
		return env(DATA_ENV) != null || env(CACHE_ENV) != null;
		#end
	}

	/** Root of the resource filesystem: "." (the executable's directory) or MBHAXE_DATA_DIR's parent. */
	public static function fsRoot():String {
		var d = configured();
		if (d == null)
			return ".";
		var parent = Path.directory(d);
		if (parent == "")
			parent = "/";
		// A missing parent is reported by check() before anything is loaded.
		return sys.FileSystem.exists(parent) ? parent : ".";
	}

	static function fail(msg:String) {
		Sys.stderr().writeString("MBHaxe: " + msg + "\n");
		Sys.exit(2);
	}

	/** Refuse to start without a real data directory (handheld build, or MBHAXE_DATA_DIR set). */
	public static function check() {
		if (!checked())
			return;
		var conf = configured();
		var data = conf != null ? conf : Path.join([Path.directory(Sys.programPath()), "data"]);
		var where = conf != null ? '(${DATA_ENV})' : "next to the executable";
		if (conf != null && Path.withoutDirectory(conf) != "data")
			fail('${DATA_ENV}=${conf}: the directory must be called "data" (resources resolve as data/... under its parent).');
		if (!sys.FileSystem.exists(data) || !sys.FileSystem.isDirectory(data))
			fail('game data not found: ${data} must be a directory holding the Marble Blast Ultra data' + (conf != null ? ' (${DATA_ENV}).' : '.'));
		var realData = sys.FileSystem.fullPath(data);
		var expected = Path.join([sys.FileSystem.fullPath(Path.directory(data)), "data"]);
		if (realData != expected)
			fail('${data} is a symlink to ${realData}; it must be a real directory ${where}.');
	}

	static function writable(dir:String):Bool {
		try {
			if (!sys.FileSystem.exists(dir))
				sys.FileSystem.createDirectory(dir);
			var probe = Path.join([dir, ".write-test"]);
			sys.io.File.saveContent(probe, "");
			sys.FileSystem.deleteFile(probe);
			return true;
		} catch (e) {
			return false;
		}
	}

	static function relative(from:String, to:String):String {
		var a = from.split("/").filter(s -> s != "");
		var b = to.split("/").filter(s -> s != "");
		var i = 0;
		while (i < a.length && i < b.length && a[i] == b[i])
			i++;
		var parts = [for (k in i...a.length) ".."].concat(b.slice(i));
		return parts.length == 0 ? "" : parts.join("/") + "/";
	}

	/**
		The converter's tmpDir. heaps prepends the filesystem's base directory to it, so a cache
		outside the data directory is expressed relative to that base.
	**/
	public static function converterTmpDir(baseDir:String):String {
		if (!checked())
			return "data/tmp/";
		var dir = env(CACHE_ENV);
		if (dir == null) {
			if (writable(Path.join([baseDir, "data", "tmp"])))
				return "data/tmp/";
			var xdg = env("XDG_CACHE_HOME");
			var home = env("HOME");
			var base = xdg != null ? xdg : home != null ? Path.join([home, ".cache"]) : null;
			if (base == null) {
				Sys.stderr().writeString('MBHaxe: warning: cache directory ${baseDir}data/tmp is not writable and neither ${CACHE_ENV}, XDG_CACHE_HOME nor HOME is set; resources that are not already converted there will fail to load.\n');
				return "data/tmp/";
			}
			dir = Path.join([base, "mbhaxe", "converted"]);
		}
		dir = strip(sys.FileSystem.absolutePath(dir));
		if (!writable(dir))
			Sys.stderr().writeString('MBHaxe: warning: cache directory ${dir} is not writable; resources that are not already converted there will fail to load.\n');
		var real = sys.FileSystem.exists(dir) ? sys.FileSystem.fullPath(dir) : dir;
		var rel = relative(baseDir, real);
		if (rel == "" || (StringTools.startsWith(rel, "data/") && !StringTools.startsWith(rel, "data/tmp/")))
			fail('converter cache ${dir} must not be the game root or inside its data directory (other than data/tmp).');
		return rel;
	}
}
