/*
 * socks-fwd - device-side LAN dialer for sshportal (camera / embedded).
 *
 * Connects as a device, runs remote command "dialer", and answers portal
 * CHANNEL_OPEN "sshportal-dial@v1" by connecting to host:port on the local
 * LAN. Same role as `sshpc dialer`, without a Go binary.
 *
 * Example:
 *   socks-fwd -y -i /factory/key -J /bin/portal-proxy \
 *     -K 30 -p 443 cam01@cam01.ssh.pwd.pub
 */

#include "includes.h"
#include "dbutil.h"

#if DROPBEAR_MULTI && defined(DBMULTI_dbclient)
int cli_main(int argc, char **argv);
#endif

static void printhelp(const char *prog) {
	fprintf(stderr,
		"Usage: %s [dbclient options] [user@]remotehost\n"
		"\n"
		"Keep an sshportal device dialer session open. The portal opens\n"
		"sshportal-dial@v1 channels; this process dials the requested\n"
		"host:port on the device LAN and relays bytes (arbitrary SOCKS egress).\n"
		"\n"
		"  -h, --help     Show this help\n"
		"\n"
		"All options are passed to dbclient. Remote command is forced to\n"
		"'dialer'. Do not use -N or -B.\n"
		"\n"
		"Example:\n"
		"  %s -y -i /factory/key -J /bin/portal-proxy -K 30 -p 443 \\\n"
		"    cam01@cam01.ssh.pwd.pub\n",
		prog, prog);
}

static int argv_has_dialer_cmd(int argc, char **argv) {
	if (argc < 2) {
		return 0;
	}
	return strcmp(argv[argc - 1], "dialer") == 0;
}

static int argv_has_flag(int argc, char **argv, char flag) {
	int i, j;

	for (i = 1; i < argc; i++) {
		if (argv[i][0] != '-') {
			continue;
		}
		if (strcmp(argv[i], "--") == 0) {
			break;
		}
		for (j = 1; argv[i][j]; j++) {
			if (argv[i][j] == flag) {
				return 1;
			}
		}
	}
	return 0;
}

/* argv[0] → "dbclient"; append remote command "dialer" if missing. */
static void prepare_dbclient_argv(int *argc, char ***argv) {
	char **args = *argv;
	int count = *argc;
	char **newargs;
	int newcount;
	int i;
	int dest;
	int need_dialer;

	for (i = 1; i < count; i++) {
		if (strcmp(args[i], "-h") == 0 || strcmp(args[i], "--help") == 0) {
			printhelp(args[0]);
			exit(EXIT_SUCCESS);
		}
	}

	need_dialer = !argv_has_dialer_cmd(count, args);
	newcount = count + (need_dialer ? 1 : 0);
	newargs = (char **)m_malloc((size_t)(newcount + 1) * sizeof(char *));
	newargs[0] = "dbclient";
	for (dest = 1; dest < count; dest++) {
		newargs[dest] = args[dest];
	}
	if (need_dialer) {
		newargs[dest++] = "dialer";
	}
	newargs[dest] = NULL;

	*argc = dest;
	*argv = newargs;
}

#if defined(DBMULTI_socksfwd) && DROPBEAR_MULTI
int socks_fwd_main(int argc, char **argv) {
#else
int main(int argc, char **argv) {
#endif
	prepare_dbclient_argv(&argc, &argv);

	if (argv_has_flag(argc, argv, 'N')) {
		dropbear_exit("socks-fwd must not use -N (needs a dialer session)");
	}
	if (argv_has_flag(argc, argv, 'B')) {
		dropbear_exit("socks-fwd must not use -B (that is tty-fwd netcat mode)");
	}

#if DROPBEAR_MULTI && defined(DBMULTI_dbclient)
	return cli_main(argc, argv);
#else
	dropbear_exit("socks-fwd requires a multi-call binary with dbclient");
	return EXIT_FAILURE;
#endif
}
