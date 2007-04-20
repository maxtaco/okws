// -*-c++-*-
/* $Id$ */

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

#include "okd.h"
#include "okprot.h"
#include "ahutil.h"
#include "pub.h"
#include "xpub.h"
#include "svq.h"
#include "okdbg.h"

#define LDCH_ERROR(x) \
  warn << servpath << ":" << pid << ": " << x << "\n";


okch_t::okch_t (okd_t *o, const str &s)
  : myokd (o), pid (-1), servpath (s), state (OKC_STATE_NONE),
    destroyed (New refcounted<bool> (false)),
    per_svc_nfd_in_xit (0),
    _n_sent (0), _last_restart (okwstime ()),
    _too_busy (false)
{
  myokd->insert (this);
}

okch_t::~okch_t ()
{
  while (conqueue.size ()) 
    myokd->error (conqueue.pop_front (), HTTP_SRV_ERROR);
  myokd->remove (this);
  *destroyed = true;
}

void
okch_t::closed_fd ()
{
  // warn << "debug: dec:  " << per_svc_nfd_in_xit << "\n";
  per_svc_nfd_in_xit --;
  myokd->closed_fd ();
}

void
okch_t::clone (ref<ahttpcon_clone> xc)
{
  if (!ctlx || ctlx->ateof () || state != OKC_STATE_SERVE) {

    if (state == OKC_STATE_CRASH || state == OKC_STATE_HOSED 
	|| conqueue.size () >= ok_con_queue_max) {

      myokd->error (xc, HTTP_SRV_ERROR, make_generic_http_req (servpath));

    } else {
      //warn << "queued con\n"; // XX debug
      conqueue.push_back (xc);
    }

  } else if ((ok_svc_fd_quota && per_svc_nfd_in_xit > int (ok_svc_fd_quota))
	     || _too_busy) {
    // warn << "debug: fail: " << per_svc_nfd_in_xit << "\n";

    if (_too_busy)
      warn << "**WARNING: Service " << servpath 
	   << " too busy to accept new connections\n";
    else
      warn << "**WARNING: Service " << servpath << " appears unresponsive!\n";

    myokd->error (xc, HTTP_UNAVAILABLE, make_generic_http_req (servpath));

  } else {
    if (ok_svc_fd_quota) {
      // warn << "debug: inc:  " << per_svc_nfd_in_xit << "\n";
      per_svc_nfd_in_xit ++;
      xc->reset_close_fd_cb (wrap (this, &okch_t::closed_fd));
    }
    send_con_to_service (xc);
  }
}

void
okch_t::shutdown (oksig_t g, cbv cb)
{
  if (clnt) {
    // note that no authentication needed for this kill signal.
    if (g == OK_SIG_ABORT) {
      CH_ERROR ("aborting unresponsive child\n");
      kill ();
      (*cb) ();
    } else {
      if (OKDBG2(OKD_SHUTDOWN)) {
	CH_CHATTER ("sending OKCTL_KILL to client");
      }
	
      clnt->seteofcb (wrap (this, &okch_t::shutdown_cb1, cb));
      clnt->call (OKCTL_KILL, &g, NULL, aclnt_cb_null);

      // don't answer any more pub messages
      state = OKC_STATE_KILLING;
    }
  } else {
    shutdown_cb1 (cb);
  }
}

void
okch_t::got_new_ctlx_fd (int fd, int p)
{
  pid = p;
  ctlx = axprt_unix::alloc (fd, ok_axprt_ps);
  ctlcon (wrap (this, &okch_t::dispatch, destroyed));
  state = OKC_STATE_LAUNCH_SEQ_1;
  start_chld ();
}

tamed void
okch_t::send_con_to_service (ref<ahttpcon_clone> xc)
{
  tvars {
    okctl_sendcon_arg_t arg;
    okctl_sendcon_res_t res;
    clnt_stat err;
    ptr<bool> df;
    sockaddr_in *sin (NULL);
  }

  df = destroyed;

  if (xc->timed_out ()) {
    CH_ERROR ("Connection timed out (fd=" << xc->getfd () 
	     << "): not forwarding to child");
  } else if (xc->getfd () < 0) {
    CH_ERROR ("Dead file descriptor encountered");
  } else {
    inc_n_sent ();
    sin = xc->get_sin ();
    arg.sin.setsize (sizeof (*sin));
    memcpy (arg.sin.base (), (void *)sin, sizeof (*sin));

    // Hack: reclaim the FD, but hold onto the ahttpcon until
    // after the server has acked it.
    twait { 
      ctlx->sendfd (xc->takefd ());
      clnt->call (OKCTL_SEND_CON, &arg, &res, mkevent (err)); 
    }

    if (err) {
      CH_ERROR ("Error in RPC for sending connection: " << err);
    } else if (res == OK_STATUS_NOMORE) {
      if (*df) {
	CH_ERROR ("No more connections; but service died..\n");
      } else {
	CH_ERROR ("Service is busy; disabling incoming connections\n");
	_too_busy = true;
      }
    } else if (res != OK_STATUS_OK) {
      CH_ERROR ("Service rejected new connection: " << res);
    }

    //
    // XXX core-0-2 note:
    //
    // Hold on xc until we've heard back, which will trigger a callback
    // saying that one fewer FD is in transit; however, we'd do best
    // to simplify this mechanism.
    //

  }
}

//
// Need two things before we can start dispatching connections
// (and set state == OKC_STATE_SERVE):
//    (1) ptr<axprt_unix> ctlx to be handed to us by okld.
//    (2) the child to call OKCLNT_READY
//
void
okch_t::start_chld ()
{
  if (state == OKC_STATE_LAUNCH_SEQ_2 && ctlx) {

    // debug messages
    if (OKDBG2 (OKD_STARTUP))
      CH_CHATTER ("child changed to serve status; conQsize=" 
		  << conqueue.size ());
    
    state = OKC_STATE_SERVE;

    reset_n_sent ();

    // need to check that ctlx is still here every time through the 
    // loop; the service might have crashed as we were servicing
    // queued connections.
    while (conqueue.size () && ctlx)
      send_con_to_service (conqueue.pop_front ());

  }
}

void
okch_t::reset_n_sent ()
{
    _n_sent = 0; 
    _last_restart = okwstime ();
}

void
okch_t::shutdown_cb1 (cbv cb)
{
  if (OKDBG2(OKD_SHUTDOWN)) {
    CH_CHATTER ("in shutdown_cb1");
  }
  delete this;
  (*cb) ();
}

void
okch_t::handle_reenable_accept (svccb *sbp)
{
  CH_ERROR ("Service reenabled accept; can now serve new connections");
  _too_busy = false;
  sbp->reply (NULL);
}

void
okch_t::dispatch (ptr<bool> dfp, svccb *sbp)
{
  if (*dfp) {
    okdbg_warn (ERROR, "dispatch function ignored for destroyed child\n");
    return;
  }
  
  if (!sbp) {
    chld_eof ();
    return ;
  }

  u_int p = sbp->proc ();

  if (state == OKC_STATE_KILLING) {
    if (OKDBG2(OKD_SHUTDOWN))
      CH_CHATTER ("ignore RPC sent after child killed");
    sbp->ignore ();
    return;
  }

  switch (p) {
  case OKCTL_PUBCONF:
    myokd->pubconf (sbp);
    break;
  case OKCTL_READY:
    if (state == OKC_STATE_LAUNCH_SEQ_1) {
      state = OKC_STATE_LAUNCH_SEQ_2;
      start_chld ();
    } else {
      CH_ERROR ("Cannot process READY message; in wrong state: " << state);
    }
    sbp->reply (NULL);
    break;
  case OKCTL_REQ_ERRDOCS:
    myokd->send_errdoc_set (sbp);
    break;
  case OKCTL_REQ_ERRDOCS_2:
    myokd->req_errdoc_set_2 (sbp);
    break;
  case OKCTL_GETFILE:
    myokd->getfile (sbp);
    break;
  case OKCTL_LOOKUP:
    myokd->lookup (sbp);
    break;
  case OKCTL_CUSTOM_1_IN: 
    myokd->custom1_in (sbp);
    break;
  case OKCTL_CUSTOM_2_IN:
    myokd->custom2_in (sbp);
    break;
  case OKCTL_GET_STATS:
    myokd->okctl_get_stats (sbp);
    break;
  case OKCTL_REENABLE_ACCEPT:
    handle_reenable_accept (sbp);
    break;
  default:
    sbp->reject (PROC_UNAVAIL);
    break;
  }
}

void
okd_t::pubconf (svccb *sbp)
{
  if (!supports_pub1 ()) {
    warn << "Cannot call PUBCONF with Pub v1 disabled.\n";
    sbp->reject (PROC_UNAVAIL);
    return;
  }
  ptr<xpub_file_t> cf;
  if ((cf = pprox->get_pubconf ())) {
    xpub_getfile_res_t x (XPUB_STATUS_OK);
    *x.file = *cf;
    sbp->replyref (x);
  } else { 
    if (!cfq.blocked (sbp)) {
      ptr<xpub_getfile_res_t> r = New refcounted<xpub_getfile_res_t> ();
      pubd->call (PUB_CONFIG, NULL, r, wrap (this, &okd_t::pubconfed, r));
    }
  }
}

void
okd_t::pubconfed (ptr<xpub_getfile_res_t> r, clnt_stat err)
{
  if (err) {
    r->set_status (XPUB_STATUS_ERR);
    *r->error = strbuf () << err;
  } else if (r->status == XPUB_STATUS_OK) {
    pprox->cache_pubconf (*r->file);
  }
  cfq.finish (r);
}


void
okd_t::lookup (svccb *sbp)
{
  if (!supports_pub1 ()) {
    warn << "Cannot call LOOKUP without Pub v1 enabled.\n";
    sbp->reject (PROC_UNAVAIL);
    return;
  }

  xpub_fn_t *x = sbp->Xtmpl getarg<xpub_fn_t> ();
  xpub_lookup_res_t res;
  if (pprox->lookup (*x, &res)) 
    sbp->replyref (res);
  else {
    pfnm_t fn = *x;
    if (!luq.inq (fn, sbp)) {
      ptr<xpub_lookup_res_t> resp = New refcounted<xpub_lookup_res_t> ();
      pubd->call (PUB_LOOKUP, x, resp, 
		  wrap (this, &okd_t::lookedup, fn, resp));
    }
  }
}

void
okd_t::lookedup (str fn, ptr<xpub_lookup_res_t> r, clnt_stat err)
{
  if (err) {
    r->set_status (XPUB_STATUS_ERR);
    *r->error = strbuf () << err;
  } else if (r->status == XPUB_STATUS_OK) {
    phashp_t hsh = phash_t::alloc (*r->hash);
    pprox->cache (fn, hsh);
  }
  luq.finish (fn, r);
}

void
okch_t::repub (ptr<ok_repub_t> rpb)
{
  if (!clnt) {
    *rpb->res << (strbuf ("Cannot repub; client not yet initialized: ")
		  << servpath);
  } else {
    clnt->call (OKCTL_UPDATE, &rpb->new_fnset, &rpb->xst,
		wrap (this, &okch_t::repub_cb, rpb));
  }
}

void
okch_t::repub_cb (ptr<ok_repub_t> rpb, clnt_stat err)
{
  if (err) 
    *rpb->res << (strbuf ("repub error: ") << err);
  else 
    rpb->res->add (rpb->xst);
}

void
okd_t::getfile (svccb *sbp)
{
  if (!supports_pub1 ()) {
    warn << "Cannot call OKCTL_GETFILE without Pub v1 running.\n";
    sbp->reject (PROC_UNAVAIL);
    return;
  }
  xpubhash_t *xh = sbp->Xtmpl getarg<xpubhash_t> ();
  phashp_t hsh = phash_t::alloc (*xh);
  xpub_getfile_res_t res;
  if (pprox->getfile (hsh, &res)) 
    sbp->replyref (res);
  else {
    if (!gfq.inq (hsh, sbp)) {
      ptr<xpub_getfile_res_t> resp = New refcounted<xpub_getfile_res_t> ();
      pubd->call (PUB_GETFILE, hsh, resp, 
		  wrap (this, &okd_t::gotfile, hsh, resp));
    }
  }
}

void
okd_t::gotfile (phashp_t hsh, ptr<xpub_getfile_res_t> res, clnt_stat err)
{
  if (err) {
    res->set_status (XPUB_STATUS_ERR);
    *res->error = strbuf () << err;
  } else if (res->status == XPUB_STATUS_OK) {
    pprox->cache (*res->file);
  }
  gfq.finish (hsh, res);
}

void
okd_t::send_errdoc_set (svccb *sbp)
{
  if (!supports_pub1 ()) {
    warn << "Cannot call REQ_ERRDOCS without Pub v1 enabled.\n";
    sbp->reject (PROC_UNAVAIL);
    return;
  }
  sbp->replyref (xeds);
}

void
okch_t::kill ()
{
  CH_CHATTER ("disconnecting from child");
  ctlx = NULL;
  clnt = NULL;
  srv = NULL;
  state = OKC_STATE_NONE;
}

void
okch_t::custom2_out_cb (ptr<ok_custom2_trig_t> trig,
			ptr<ok_custom_data_t> res, clnt_stat err)
{
  if (err)
    trig->add_err (servpath, OK_STATUS_ERR);
  else
    trig->add_succ (servpath, *res);
}

void
okch_t::custom2_out (ptr<ok_custom2_trig_t> trig, const ok_custom_data_t &x)
{
  ptr<ok_custom_data_t> resp = New refcounted<ok_custom_data_t> ();
  
  if (clnt && !clnt->xprt ()->ateof ()) {
    clnt->call (OKCTL_CUSTOM_2_OUT, &x, resp, 
		wrap (this, &okch_t::custom2_out_cb, trig, resp));
  } else {
    trig->add_err (servpath, OK_STATUS_DEADCHILD);
    CH_ERROR ("child in state=" << state << 
	     "swallowing OKCTL_CUSTOM_1_OUT RPC.");
  }
}

//
// route a CUSTOM1 message out to the appropriate child
//
void
okch_t::custom1_out (const ok_custom_data_t &x)
{
  // XXX want to collect success information and so on from this guy
  // (as in repub)
  if (clnt && !clnt->xprt ()->ateof ()) {
    clnt->call (OKCTL_CUSTOM_1_OUT, &x, NULL, aclnt_cb_null);
  } else {
    CH_ERROR ("child in state=" << state << 
	     "swallowing OKCTL_CUSTOM_1_OUT RPC.");
  }
}

void
okch_t::chld_eof ()
{
  warn << servpath << ": child process died (pid " << pid << ")\n";
  ctlx = NULL;
  srv = NULL;
  clnt = NULL;

  if (myokd && !myokd->in_shutdown ()) {
    state = OKC_STATE_CRASH;
  } else 
    state = OKC_STATE_NONE;
}

void
okch_t::to_status_xdr (oksvc_status_t *st)
{
  memset ((void *)st, 0, sizeof (*st));
  st->pid = pid;
  st->servpath = servpath;
  st->n_served = _n_sent;
  st->uptime = okwstime () - _last_restart;
}
