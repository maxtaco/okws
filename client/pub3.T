// -*-c++-*-
/* $Id: pubd.T 4245 2009-03-24 00:11:42Z max $ */

/*
 *
 * Copyright (C) 2002-2004 Maxwell Krohn (max@okcupid.com)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2, or (at
 * your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
 * USA
 *
 */

#include "pub.h"
#include "pub_parse.h"
#include "xpub.h"
#include <unistd.h>
#include <stdlib.h>
#include "parseopt.h"
#include "pslave.h"
#include "pubutil.h"
#include "okdbg.h"
#include "pub2.h"
#include "pub3.h"
#include "okrfn.h"

//-----------------------------------------------------------------------

namespace pub3 {

  class eng_t {
  public:
    eng_t () : _opt (0), _ppt (NULL) {}
    void init (int argc, char **argv, bool *gop, evi_t ev, CLOSURE);
    void run (evi_t ev, CLOSURE);
  private:
    void run_file (str s, evi_t ev, CLOSURE);

    int _opt;
    str _jaildir;
    str _config;
    pub_parser_t *_ppt;
    ptr<pub2::local_publisher_t> _pub;
    vec<str> _files;
    str _argfile;
    pub3::obj_dict_t _dict;
  };

};

//-----------------------------------------------------------------------

tamed void
pub3::eng_t::run_file (str f, evi_t ev)
{
  tvars {
    bool ok;
    zbuf out;
  }
  twait { _pub->run (&out, f, mkevent (ok), _dict.dict (), _opt); }
  if (!ok) {
    warn << "** pub failed on file: " << f << "\n";
  } else {
    strbuf b;
    out.to_strbuf (&b, false);
    b.tosuio ()->output (1);
  }
  ev->trigger ( ok ? 0 : -1);
}

//-----------------------------------------------------------------------

tamed void
pub3::eng_t::run (evi_t ev)
{
  tvars {
    int rc (0);
    size_t i;
    bool b (true);
  }

  if (_argfile) {
    twait { _pub->run_cfg (_argfile, mkevent (b), _dict.dict ()); }
  }

  if (!b) { 
    warn << "** failed to parse arguments file: " << _argfile << "\n";
    rc = -2;
  }
  

  for (i = 0; i < _files.size () && rc == 0; i++) {
    twait { run_file (_files[i], mkevent (rc)); }
  }

  ev->trigger (rc);
}

//-----------------------------------------------------------------------

static void
usage ()
{
  warnx << "usage: " << progname 
	<< " [-wevh] [-j <jaildir>] [-f <conf>] [-o <objfile>] [-a <argfile>] "
	<< "<file-1> <file-2> ..\n"
	<< "    (Pub v3, OKWS" << OKWS_VERSION << ")\n";
}


//-----------------------------------------------------------------------

tamed void
pub3::eng_t::init (int argc, char **argv, bool *gop, evi_t ev)
{
  tvars {
    bool run (true);
    int rc;
    int ch;
    const char *e, *v;
    bool have_cfg;
    struct stat sb;
  }

  zinit ();
  set_debug_flags ();

  _ppt = pub_parser_t::alloc (true);

  if ((e = getenv ("PUBCONF")) && (v = getenvval (e)) && *v) {
    _config = v;
  }

  while ((ch = getopt (argc, argv, "a:diwej:f:vh")) != -1) {
    switch (ch) {
    case 'a':
      _argfile = optarg;
      break;
    case 'i':
      _opt |= P_IINFO;
      break;
    case 'd':
      _opt |= P_DEBUG;
      break;
    case 'w':
      _opt |= P_WSS; 
      break;
    case 'e':
      _opt |= P_VISERR;
      break;
    case 'j':
      _jaildir = optarg;
      break;
    case 'f':
      _config = optarg;
      break;
    case 'v':
      _opt |= P_VERBOSE;
      break;
    case 'h':
      usage ();
      run = false;
      break;
    default:
      usage ();
      run = false;
      rc = -2;
      break;
    }
  }

  if (!run) {
    /* noop */
  } else {
    argc -= optind;
    argv += optind;

    for (int i = 0; i < argc; i++) {
      _files.push_back (argv[i]);
    }
    
    if (!_config) {
      _config = okws_etcfile (ok_pub_config);
    }
    
    _pub = New refcounted<pub2::local_publisher_t> (_ppt, _opt);
    
    have_cfg = false;
    if (_config) {
      twait { _pub->run_cfg (_config, mkevent (have_cfg)); }
    }
    
    if (!have_cfg)  {
      warn << "pubd running without default variable bindings\n";
    }
    
    if (!_jaildir) {
      if (!_pub->cfg ("JailDir", &_jaildir, true)) {
	warn << "XX cannot find a jail directory!!\n";
	warn << "XX   - none was specified with -j and "
	     << "no 'JailDir' found in config file.\n";
      }
    }
    
    if (!_jaildir) {
      /* issues ahead! */
    } else if (stat (_jaildir.cstr (), &sb) != 0) {
      warn << "XX no directory found for JailDir: " << _jaildir << "\n";
      _jaildir = NULL;
    } else if (!S_ISDIR(sb.st_mode)) {
      warn << "XX supposed 'JailDir' is not a directory: " << _jaildir << "\n";
      _jaildir = NULL;
    }
    
    if (!_jaildir) {
      run = false;
      rc = -1;
    } else if (_files.size () == 0) {
      run = false;
      rc = -1;
      warn << "XX no files given! need at least one\n";
      usage ();
    } else {
      _ppt->setjail_virtual (_jaildir);
    }
  }
  
  *gop = run;
  ev->trigger (rc);
}

//-----------------------------------------------------------------------

tamed static void
main2 (int argc, char **argv)
{
  tvars {
    int rc (0);
    bool go;
    pub3::eng_t eng;
  }

  // set up the runtime library!
  pub3::rfn_factory_t::set (New refcounted<rfn1::std_factory_t> ());

  twait { eng.init (argc, argv, &go, mkevent (rc)); }
  if (go) {
    twait { eng.run (mkevent (rc)); }
  }
  exit (rc);
}

//-----------------------------------------------------------------------

int
main (int argc, char *argv[])
{
  setprogname (argv[0]);
  main2 (argc, argv);
  amain ();
}

//-----------------------------------------------------------------------