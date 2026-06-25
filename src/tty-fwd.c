/*
 * tty-fwd - forward a local PTY to a remote TCP endpoint over SSH.
 *
 * Runs the given shell in a pseudo-terminal and connects the PTY master to
 * dbclient netcat mode (-B) via stdin/stdout. No local listen port is opened;
 * the device only makes an outbound SSH connection.
 *
 * Example:
 *   tty-fwd -y -i /factory/key -B 127.0.0.1:9000 tunnel@jump.example.com
 */

#include "includes.h"
#include "dbutil.h"
#include "sshpty.h"

#if !DROPBEAR_CLI_NETCAT
#error "tty-fwd requires DROPBEAR_CLI_NETCAT"
#endif

#if DROPBEAR_MULTI && defined(DBMULTI_dbclient)
int cli_main(int argc, char **argv);
#endif

#if defined(DROPBEAR_FORCE_SHELL)
#define TTYFWD_DEFAULT_SHELL DROPBEAR_FORCE_SHELL
#else
#define TTYFWD_DEFAULT_SHELL "/bin/sh"
#endif

#define TTYFWD_DEFAULT_TERM "xterm-256color"
#define TTYFWD_DEFAULT_ROWS 24
#define TTYFWD_DEFAULT_COLS 80

static pid_t shell_pid = -1;

/* Initial PTY geometry / terminal type for the forwarded shell. There is no
 * resize channel back from the cloud side, so these define the fixed terminal
 * size full-screen programs (top, vi) will use. */
static const char *ttyfwd_term = TTYFWD_DEFAULT_TERM;
static int ttyfwd_rows = TTYFWD_DEFAULT_ROWS;
static int ttyfwd_cols = TTYFWD_DEFAULT_COLS;

static void shell_cleanup(void) {
	if (shell_pid <= 0) {
		return;
	}
	kill(shell_pid, SIGHUP);
	(void)waitpid(shell_pid, NULL, 0);
	shell_pid = -1;
}

static void shell_signal_handler(int sig) {
	(void)sig;
	shell_cleanup();
	_exit(EXIT_FAILURE);
}

static void printhelp(const char *prog) {
	fprintf(stderr,
		"Usage: %s [--shell path] [dbclient options] -B host:port [user@]remotehost\n"
		"\n"
		"Run a shell in a local PTY and forward its I/O to a remote TCP endpoint\n"
		"over SSH (dbclient netcat mode). The device does not listen on any port.\n"
		"\n"
		"  --shell path   Shell to run (default: %s)\n"
		"  --term name    TERM for the shell (default: %s)\n"
		"  --rows n       Initial PTY rows (default: %d)\n"
		"  --cols n       Initial PTY cols (default: %d)\n"
		"  -h, --help     Show this help\n"
		"\n"
		"All other options are passed to dbclient. -B host:port is required.\n"
		"\n"
		"Example:\n"
		"  %s -y -i /factory/key -B 127.0.0.1:9000 tunnel@jump.example.com\n",
		prog, TTYFWD_DEFAULT_SHELL, TTYFWD_DEFAULT_TERM,
		TTYFWD_DEFAULT_ROWS, TTYFWD_DEFAULT_COLS, prog);
}

/* True if argv contains dbclient's -B netcat option. */
static int argv_has_netcat_opt(int argc, char **argv) {
	int i, j;

	for (i = 1; i < argc; i++) {
		if (argv[i][0] != '-') {
			continue;
		}
		for (j = 1; argv[i][j]; j++) {
			if (argv[i][j] != 'B') {
				continue;
			}
			if (argv[i][j + 1] != '\0') {
				return 1;
			}
			if (i + 1 < argc) {
				return 1;
			}
			return 0;
		}
	}
	return 0;
}

/* Parse --shell / -h / --, compact argv for cli_main with argv[0]="dbclient". */
static void parse_ttyfwd_opts(int *argc, char ***argv, const char **shell) {
	char **args = *argv;
	int count = *argc;
	int i = 1;
	int dest = 1;

	*shell = TTYFWD_DEFAULT_SHELL;

	while (i < count) {
		if (strcmp(args[i], "--shell") == 0) {
			if (i + 1 >= count) {
				dropbear_exit("--shell requires an argument");
			}
			*shell = args[++i];
			i++;
			continue;
		}
		if (strcmp(args[i], "--term") == 0) {
			if (i + 1 >= count) {
				dropbear_exit("--term requires an argument");
			}
			ttyfwd_term = args[++i];
			i++;
			continue;
		}
		if (strcmp(args[i], "--rows") == 0) {
			if (i + 1 >= count) {
				dropbear_exit("--rows requires an argument");
			}
			ttyfwd_rows = atoi(args[++i]);
			if (ttyfwd_rows <= 0) {
				dropbear_exit("--rows must be positive");
			}
			i++;
			continue;
		}
		if (strcmp(args[i], "--cols") == 0) {
			if (i + 1 >= count) {
				dropbear_exit("--cols requires an argument");
			}
			ttyfwd_cols = atoi(args[++i]);
			if (ttyfwd_cols <= 0) {
				dropbear_exit("--cols must be positive");
			}
			i++;
			continue;
		}
		if (strcmp(args[i], "-h") == 0 || strcmp(args[i], "--help") == 0) {
			printhelp(args[0]);
			exit(EXIT_SUCCESS);
		}
		if (strcmp(args[i], "--") == 0) {
			i++;
			break;
		}
		if (args[i][0] == '-') {
			/* dbclient option */
			break;
		}
		/* remote host or other positional arg for dbclient */
		break;
	}

	args[0] = "dbclient";
	memmove(&args[1], &args[i], (size_t)(count - i) * sizeof(char *));
	dest = count - i + 1;
	args[dest] = NULL;
	*argc = dest;
	*argv = args;
}

static void start_shell(const char *shell, int master, int slave, const char *tty_name) {
	struct passwd *pw;

	shell_pid = fork();
	if (shell_pid < 0) {
		dropbear_exit("fork failed: %s", strerror(errno));
	}

	if (shell_pid != 0) {
		return;
	}

	/* child */
	close(master);
	pty_make_controlling_tty(&slave, tty_name);

	/* Give the PTY a fixed initial size so full-screen programs (top, vi)
	 * can position the cursor and redraw. There is no resize channel back
	 * from the cloud, so this size stays constant for the session. */
	{
		struct winsize ws;
		memset(&ws, 0, sizeof(ws));
		ws.ws_row = (unsigned short)ttyfwd_rows;
		ws.ws_col = (unsigned short)ttyfwd_cols;
		(void)ioctl(slave, TIOCSWINSZ, &ws);
	}

	setenv("TERM", ttyfwd_term, 1);

	if (dup2(slave, STDIN_FILENO) < 0
			|| dup2(slave, STDOUT_FILENO) < 0
			|| dup2(slave, STDERR_FILENO) < 0) {
		_exit(EXIT_FAILURE);
	}
	close(slave);

	pw = getpwuid(getuid());
	if (pw) {
		pty_setowner(pw, (char*)tty_name);
	}

	execl(shell, shell, (char*)NULL);
	_exit(EXIT_FAILURE);
}

#if defined(DBMULTI_ttyfwd) && DROPBEAR_MULTI
int tty_fwd_main(int argc, char **argv) {
#else
int main(int argc, char **argv) {
#endif
	const char *shell;
	int master = -1;
	int slave = -1;
	char tty_name[64];

	parse_ttyfwd_opts(&argc, &argv, &shell);

	if (!argv_has_netcat_opt(argc, argv)) {
		dropbear_exit("tty-fwd requires dbclient -B host:port (netcat mode)");
	}

	if (pty_allocate(&master, &slave, tty_name, sizeof(tty_name)) == 0) {
		dropbear_exit("Failed to allocate pty");
	}

	start_shell(shell, master, slave, tty_name);
	close(slave);

	if (signal(SIGINT, shell_signal_handler) == SIG_ERR
			|| signal(SIGTERM, shell_signal_handler) == SIG_ERR) {
		dropbear_exit("signal() error");
	}
	atexit(shell_cleanup);

	if (dup2(master, STDIN_FILENO) < 0 || dup2(master, STDOUT_FILENO) < 0) {
		dropbear_exit("dup2 failed: %s", strerror(errno));
	}
	close(master);

#if DROPBEAR_MULTI && defined(DBMULTI_dbclient)
	return cli_main(argc, argv);
#else
	dropbear_exit("tty-fwd requires a multi-call binary with dbclient");
	return EXIT_FAILURE;
#endif
}
