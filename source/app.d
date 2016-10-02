import std.algorithm : joiner;
import std.concurrency;
import std.conv;
import std.file;
import std.json;
import std.net.curl;
import std.parallelism : parallel;
import std.stdio;
import std.string;

int main(string[] args)
{
	import std.getopt;

	string filename = "github-pubkey.csv";
	long id = 0;
	bool askPassword = false;

	auto help = getopt(args, "output|o", &filename,
			"id|i", &id,
			"ask-password", &askPassword);

	if (help.helpWanted) {
		writeln("Usage: github-pubkey-crawl [options...]");
		writeln("Options:");
		writeln(" -o, --output FILE     Specify an output file.");
		writeln(" -i, --index ID        Specify a starting id to crawl.");
		writeln("                       A negative value (including 0) will continue the previous crawl if it can.");
		writeln("                       If no other crawl were done previously, it will start from the beginning,");
		writeln("     --ask-password    Do not cache the password on disk in the «login-info» file and ask for it instead.");
		writeln(" -h, --help            Display this help.");
		return 0;
	}

	if (id <= 0) {
		id = getLastId(filename);
	}

	Tid print = spawn(&printworker, thisTid, filename);
	Tid pubkey = spawn(&pubkeyworker, thisTid, print);

	int retcode = userworker(pubkey, getAuthentication(askPassword), id);

	// TODO(vloup): wait for confirmation of children thread stop?

	return retcode;
}

long getLastId(string filename)
{
	import std.csv;
	import std.typecons;

	if (!exists(filename)) {
		return 0;
	}

	/* empty file */
	if (getSize(filename) == 0) {
		return 0;
	}

	File file = File(filename, "r");

	long id = 0;
	foreach(record;	file.byLine().joiner("\n")
			.csvReader!(Tuple!(long, string, string))(',')) {
		id = record[0];
	}

	return id;
}

HTTP getAuthentication(bool askPassword)
{
	import std.process : executeShell;

	enum filename = "login-info";

	string username, passwd;

	if (exists(filename) && !askPassword) {
		File login = File(filename, "r");
		JSONValue j = parseJSON(login.byLine().joiner("\n"));
		username = j["username"].str;
		passwd = j["passwd"].str;
	} else {
		write("login: ");
		username = chomp(readln());

		write("password: ");
		executeShell("stty -echo");
		passwd = chomp(readln());
		executeShell("stty echo");
		write("\n");

		if (!askPassword) {
			File login = File(filename, "w");
			JSONValue j = ["username": username, "passwd": passwd];
			login.writeln(j.toString());
		}
	}

	auto conn = HTTP();
	conn.setAuthentication(username, passwd);

	return conn;
}

int userworker(Tid pubkey, HTTP conn, long startid)
{
	enum API_ADDRESS = "https://api.github.com/users?since=";
	bool loop = true;
	long id = startid;
	int retcode = 0;

	while (loop) {
		try {
			auto raw = get(API_ADDRESS ~ to!string(id), conn);

			JSONValue[] array = parseJSON(raw).array();

			if (array.length != 0) {
				foreach (ref a; parallel(array)) {
					send(pubkey, a["id"].integer, a["login"].str);
				}
				id = array[$ - 1]["id"].integer;
			} else {
				loop = false;
				writeln("[DONE] Finished crawling.");
			}
		} catch (CurlException ce) {
			int statuscode = conn.statusLine().code;
			if (statuscode == 401) {
				stderr.writeln("[ERROR] Bad credentials.");
				loop = false;
				retcode = -1;
			} else if (statuscode == 403) {
				stderr.writeln("[ERROR] API call exhausted.");
				loop = false;
				retcode = -2;
			} else {
				stderr.writeln("[ERROR] ", ce.msg);
				loop = false;
				retcode = -3;
			}
		}
	}

	return retcode;
}

void pubkeyworker(Tid parentTid, Tid printworker)
{
	enum GITHUB_ADDRESS = "https://github.com/";

	bool loop = true;
	HTTP conn = HTTP();

	while (loop) {
		try {
			receive(
				(long id, ref string login) {
					try {
						foreach (line; parallel(byLine(GITHUB_ADDRESS ~ login ~ ".keys", KeepTerminator.no, '\n', conn))) {
							/*
							 * Weird users such as 'session' or 'readme' return bad data.
							 * Luckily, the first line of that kind of input is empty, 
							 * so we do detect them like that and ignore them
							 */
							if (line.length == 0) {
								break;
							}
							send(printworker, id, login, to!string(line));
						}
					} catch (CurlException ce) {
						writeln("User ", login, ": Got a ", conn.statusLine().code, " HTTP return code.");
					}
				}
			);
		} catch (OwnerTerminated ot) {
			stderr.writeln("Stopping pubkey worker.");
			loop = false;
		}
	}
}

void printworker(Tid parentTid, string filename)
{
	File output = File(filename, "a");
	bool loop = true;
	while (loop) {
		try {
			receive(
				(long id, ref string login, ref string key) {
					output.writefln("%d,\"%s\",\"%s\"", id, login, key);
				}
			);
			output.flush();
		} catch (OwnerTerminated ot) {
			stderr.writeln("Stopping print worker.");
			loop = false;
		}
	}
}
