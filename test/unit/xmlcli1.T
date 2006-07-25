// -*-c++-*-
/* $Id: okcgi.h 1682 2006-04-26 19:17:22Z max $ */

#include "okxml.h"
#include "abuf_pipe.h"
#include "okxmlparse.h"
#include "tame.h"
#include "rxx.h"
#include "okwcxml.h"
#include "okxmlobj.h"

static void usage (void)
{
  warnx << "usage: " << progname << "[-d] [-t<timeout>] <url>\n";
  exit (1);
}

static rxx url_rxx ("http://([^:/]+)(:(\\d+)/)?(.*)");

TAMED static void
main2 (int argc, char **argv)
{
  VARS {
    xml_outreq_t req;
    xml_inresp_t resp;
    str hostname;
    u_int16_t port (80);
    ptr<okwc2_xml_t> cli;
    str port_str;
    int timeout (0);
    str filename;
    int status;
    str body;
    int ch;
    bool debug (false);
    int code;
    str msg;
    bool verbose (false);
	int w;
  }

  while ((ch = getopt (argc, argv, "vdt:")) != -1) {
    switch (ch) {
    case 'd':
      debug = true;
      break;
    case 'v':
      verbose = true;
      break;
    case 't':
      if (!convertint (optarg, &timeout))
	usage ();
      break;
    default:
      usage ();
      break;
    }
  }
  
  argc -= optind;
  argv += optind;
  

  if (argc != 1) usage ();

  if (!url_rxx.match (argv[0]))
    usage ();

  hostname = url_rxx[1];
  port_str = url_rxx[3];
  if (port_str && port_str.len ())
    assert (convertint (port_str, &port));
  filename = url_rxx[4];
  
  cli = New refcounted<okwc2_xml_t> (hostname, port, filename);

  req.set_method_name ("foo");

  req[0] = "hi";
  req[1] = 3;
  req[2] = true;
  req[3]("A") = "member-A";
  req[3]("B") = "member_B";
  req[3]("array")[0] = 0;
  req[3]("array")[1] = 2;

  if (debug) {
    BLOCK { cli->call_dump (req, @(status, body), timeout); }
    warn << "debug status: " << status << "\n";
    if (body) 
      warn << "body: " << body;
  } else {
    BLOCK { cli->call (req, @(status, resp), timeout); }
    warn << "status: " << status << "\n";
    if (status == HTTP_OK) {
      if (resp.is_fault (&code, &msg)) {
	warn << "Fault(" << code << "): ";
	if (msg) warnx << msg;
	warnx << "\n";
      } else if (verbose) {
	zbuf z;
	resp.output (z);
	strbuf b;
	z.to_strbuf (&b, false);
	warn << b << "\n";
      } else {
	strbuf b;
	resp.output_python (b);
	warn << b << "\n";
      }
    }
  }
  w = 3;
  warnx << "waiting " << w << " seconds before exit\n";
  delaycb (w, 0, wrap (exit, 0));
}


int
main (int argc, char *argv[])
{
  setprogname (argv[0]);
  main2 (argc, argv);
  amain ();

}