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

#include "mystmt.h"
#include <sys/time.h>
#include <time.h>

//====================================== sth_prepared_t =================

#if defined(HAVE_MYSQL_BINDFUNCS) && defined(HAVE_MYSQL_BIND)

//-----------------------------------------------------------------------

u_int64_t
sth_prepared_t::insert_id () 
{
  GIANT_UNLOCK();
  u_int64_t r = mysql_stmt_insert_id (sth);
  GIANT_LOCK();
  return r;
}

//-----------------------------------------------------------------------

sth_prepared_t::~sth_prepared_t ()
{
  if (bnds) delete [] bnds;
  GIANT_UNLOCK();
  if (sth) mysql_stmt_close (sth);
  GIANT_LOCK();
}

//-----------------------------------------------------------------------

size_t
sth_prepared_t::affected_rows () const
{
  GIANT_UNLOCK();
  size_t r = mysql_stmt_affected_rows (sth);
  GIANT_LOCK();
  return r;
}

//-----------------------------------------------------------------------

void
sth_prepared_t::clearfetch ()
{
  // clear out all fetches if we're STORING results but haven't
  // fetch any records, or if we're not storing results and there
  // are more records left to fetch
  if (state == AMYSQL_EXEC ||
      (state == AMYSQL_FETCH && (opts & AMYSQL_USERES))) 
    while (fetch2 (true) == ADB_OK) ;
}

//-----------------------------------------------------------------------

str
sth_prepared_t::dump (mybind_param_t **arr, u_int n) 
{
  strbuf b;
  b << " q-> " << qry << "\n";
  b << " p-> ";
  for (u_int i = 0; i < n; i++) {
    if (i != 0)
      b << ", ";
    b << arr[i]->to_str ();
  }
  return b;
}

//-----------------------------------------------------------------------

bool
sth_prepared_t::execute2 (MYSQL_BIND *b, mybind_param_t **arr, u_int n)
{
  // will clear any pending fetch()'s or any unused rows in
  // the case of mysql_use_result
  //
  clearfetch ();

  if (b && arr && n) {
    bind (b, arr, n);
    GIANT_UNLOCK();
    int rc = mysql_stmt_bind_param (sth, b);
    GIANT_LOCK();
    if (rc != 0) {
      err = strbuf ("bind error: ") << mysql_stmt_error (sth);
	  errno_n = mysql_stmt_errno (sth);
      return false;
    }
  }

  GIANT_UNLOCK();
  int rc = mysql_stmt_execute (sth);
  GIANT_LOCK();

  if (rc != 0) {
    err = strbuf ("execute error: ") << mysql_stmt_error (sth);
    errno_n = mysql_stmt_errno (sth);
    state = AMYSQL_NONE;
    return false;
  }
  state = AMYSQL_EXEC;
  return true;
}

//-----------------------------------------------------------------------

bool
sth_prepared_t::bind_result ()
{
  if (!bnds)
    bnds = New MYSQL_BIND[res_n];
  assert (res_arr);
  for (u_int i = 0; i < res_n; i++)
    res_arr[i].bind (&bnds[i]);
  if (mysql_stmt_bind_result (sth, bnds) != 0) {
    err = strbuf ("bind failed: ") << mysql_stmt_error (sth);
	errno_n = mysql_stmt_errno (sth);
    return false;
  }
  return true;
}

//-----------------------------------------------------------------------

void
sth_prepared_t::bind (MYSQL_BIND *b, mybind_param_t **a, u_int n)
{
  for (u_int i = 0; i < n; i++)
    a[i]->bind (&b[i]);
}

//-----------------------------------------------------------------------

adb_status_t
sth_prepared_t::fetch2 (bool bnd)
{
  // state machine update
  if (state == AMYSQL_EXEC) {
    state = AMYSQL_FETCH;
    if (!(opts & AMYSQL_USERES)) {
      GIANT_UNLOCK();
      int rc = mysql_stmt_store_result (sth);
      GIANT_LOCK();
      if (rc != 0) {
	err = strbuf ("stmt_store error (") << rc << "): " 
					    << mysql_stmt_error (sth);
	errno_n = mysql_stmt_errno (sth);
	state = AMYSQL_NONE;
	return ADB_ERROR;
      }
    }
  }

  if (bnd && !bind_result ())
    return ADB_BIND_ERROR;

  GIANT_UNLOCK();
  int rc = mysql_stmt_fetch (sth);
  GIANT_LOCK();
  if (rc == MYSQL_NO_DATA) {
    state = AMYSQL_FETCH_DONE;
    return ADB_NOT_FOUND;
  } else if (rc != 0) {
    err = strbuf("fetch error:  ") << mysql_stmt_error (sth);
    errno_n = mysql_stmt_errno (sth);
    state = AMYSQL_NONE;
    return ADB_ERROR;
  }
  assign ();
  return ADB_OK;
}

#endif //  HAVE_MYSQL_BINDFUNCS && HAVE_MYSQL_BIND

//==================================== sth_parsed_t =======================

u_int64_t
sth_parsed_t::insert_id () 
{
  GIANT_UNLOCK();
  u_int64_t r = mysql_insert_id (mysql);
  GIANT_LOCK();
  return r;
}

//-----------------------------------------------------------------------

void
sth_parsed_t::clearfetch ()
{
  if (state == AMYSQL_EXEC) {
    assert (!myres);

    GIANT_UNLOCK();
    myres = (opts & AMYSQL_USERES) ? mysql_use_result (mysql)
      : mysql_store_result (mysql);
    GIANT_LOCK();

    if (myres) 
      warn << "exec() called without fetch() on query: " << last_qry << "\n";
    state = AMYSQL_FETCH;
  }
  if (state == AMYSQL_FETCH && (opts & AMYSQL_USERES)) {
    int rc = 1;
    while (rc) {
      GIANT_UNLOCK();
      mysql_fetch_row (myres);
      GIANT_LOCK();
    }
  }

  if (myres) {
    mysql_free_result (myres);
    myres = NULL;
  }

  if (state == AMYSQL_FETCH)
    state = AMYSQL_FETCH_DONE;
}

//-----------------------------------------------------------------------

adb_status_t 
sth_parsed_t::fetch2 (bool bnd)
{
  if (!myres) {
    state = AMYSQL_FETCH;

    GIANT_UNLOCK();
    myres = (opts & AMYSQL_USERES) ? mysql_use_result (mysql) :
      mysql_store_result (mysql);
    GIANT_LOCK();

    if (myres) {
      GIANT_UNLOCK();
      my_res_n = mysql_num_fields (myres);
      GIANT_LOCK();
    } else {
      err = strbuf ("MySQL result error: ") << mysql_error (mysql);
      errno_n = mysql_errno (mysql);
      state = AMYSQL_NONE;
      return ADB_ERROR;
    }
  }

  GIANT_UNLOCK();
  MYSQL_ROW row = mysql_fetch_row (myres);
  GIANT_LOCK();

  if (!row) {
    state = AMYSQL_FETCH_DONE;
    return ADB_NOT_FOUND;
  }

  GIANT_UNLOCK();
  length_arr = mysql_fetch_lengths (myres);
  GIANT_LOCK();

  row_to_res (&row, myres);
  return ADB_OK;
}

//-----------------------------------------------------------------------

void
sth_parsed_t::row_to_res (MYSQL_ROW *row, MYSQL_RES *res)
{
  MYSQL_FIELD *ff = NULL;
  u_int lim = min (my_res_n, res_n);

  for (u_int i = 0; i < lim && !ff; i++) {
    if (res_arr[i].is_xdr_union_type ()) { 
      GIANT_UNLOCK();
      ff = mysql_fetch_fields (myres);
      GIANT_LOCK();
    }
  }

  for (u_int i = 0; i < lim; i++) {
    res_arr[i].read_str ((*row)[i], 
			 length_arr ? length_arr[i] : 0,
			 ff ? ff[i].type : MYSQL_TYPE_NULL);
			 
  }
}

//-----------------------------------------------------------------------

sth_parsed_t::~sth_parsed_t ()
{
  if (myres) {
    mysql_free_result (myres);
    myres = NULL;
  }
  dealloc_bufs ();
}

//-----------------------------------------------------------------------

void
sth_parsed_t::alloc_bufs ()
{
  if (!bufs && n_iparam) {
    bufs = New char *[n_iparam];
    memset ((void *)bufs, 0, sizeof (char *) * n_iparam);
    lens = New u_int[n_iparam];
    memset ((void *)lens, 0, sizeof (int) * n_iparam);
  }
}

//-----------------------------------------------------------------------

void
sth_parsed_t::dealloc_bufs ()
{
  if (bufs) {
    for (u_int i = 0; i < n_iparam; i++) 
      if (bufs[i]) delete [] bufs[i];
    delete [] bufs;
  }
}

//-----------------------------------------------------------------------

bool
sth_parsed_t::parse ()
{
  const char *p1, *p2;
  p1 = qry.cstr ();
  int len;
  int len_left = qry.len ();
  if (len_left == 0 || p1[0] == '?')
    return false;
    
  while (p1 && *p1 && (p2 = strchr (p1, '?'))) {
    n_iparam++;
    if ((len = p2 - p1) > 0) {
      qry_parts.push_back (str (p1, len));
      p1 = p2 + 1;
    }
    len_left -= (len + 1);
  }
  if (p1 && *p1 && len_left)
    qry_parts.push_back (str (p1, len_left));

  return true;
}

//-----------------------------------------------------------------------

str
sth_parsed_t::make_query (mybind_param_t **aarr, u_int n)
{
  alloc_bufs ();
  strbuf b;
  for (u_int i = 0; i < n; i++) {
    b << qry_parts[i];
    aarr[i]->to_qry (mysql, &b, &bufs[i], &lens[i]);
  }
  for (u_int i = n; i < qry_parts.size (); i++)
    b << qry_parts[i];

  return b;
}

//-----------------------------------------------------------------------

bool
sth_parsed_t::execute2 (MYSQL_BIND *dummy, mybind_param_t **aarr, u_int n)
{

  //
  // will clear any pending fetch()'s or any unused rows in the
  // case of mysql_use_result.
  //
  // will also clear and free myres.
  //
  clearfetch ();

  if (n != n_iparam) {
    err = strbuf("cannot prepare query: wrong number of "
		 "input parameters (n = ") 
		   << n << ", n_iparam = " << n_iparam << ")";
    return false;
  }
  str q = make_query (aarr, n);

  last_qry = q;

  GIANT_UNLOCK();
  int rc = mysql_real_query (mysql, q.cstr (), q.len ());
  GIANT_LOCK();

  if (rc != 0) {
    err = strbuf ("Query execution error: ") << mysql_error (mysql) << "\n";
    errno_n = mysql_errno (mysql);
    state = AMYSQL_NONE;
    return false;
  }
  state = AMYSQL_EXEC;
  return true;
}

//-----------------------------------------------------------------------

str
sth_parsed_t::dump (mybind_param_t **aarr, u_int n)
{
  return make_query (aarr, n);
}

//-----------------------------------------------------------------------

const MYSQL_FIELD *
sth_parsed_t::fetch_fields (size_t *sz)
{
  const MYSQL_FIELD *ret = NULL;

  GIANT_UNLOCK();
  myres = mysql_store_result (mysql);
  GIANT_LOCK();

  if (myres) {
    unsigned int nf = mysql_num_fields (myres);
    my_res_n = nf; // whenver we set myres, also set my_res_n, and bump state
    state = AMYSQL_FETCH;
    *sz = nf;

    GIANT_UNLOCK();
    ret = mysql_fetch_fields (myres);
    GIANT_LOCK();
  }
  return ret;
}

//-----------------------------------------------------------------------

size_t 
sth_parsed_t::n_rows () const 
{
  size_t res = 0;
  if (myres) { res = mysql_num_rows (myres);  }
  return res;
}

//-----------------------------------------------------------------------

size_t
sth_parsed_t::affected_rows () const
{
  size_t r = mysql_affected_rows (mysql);
  return r;
}

//========================================= mystmt_t ====================

void
mystmt_t::assign ()
{
  for (u_int i = 0; i < res_n; i++) 
    res_arr[i].assign ();
}

//-----------------------------------------------------------------------

mystmt_t::~mystmt_t ()
{
  if (res_arr) delete [] res_arr;
}

//-----------------------------------------------------------------------

bool
mystmt_t::execute_argvec (const amysql_scalars_t &args)
{
  size_t n = args.size ();
  mybind_param_t **params = New mybind_param_t *[n];
  MYSQL_BIND *binds = New MYSQL_BIND[n];
  for (size_t i = 0; i < n; i++) {
    params[i] = New mybind_param_t (args[i]);
  }
  bool ret = execute1 (binds, params, n);
  for (size_t i = 0; i < n; i++) {
    delete params[i];
  }
  delete [] params;
  delete [] binds;
  return ret;
}

//-----------------------------------------------------------------------

adb_status_t 
mystmt_t::fetch_argvec (vec<amysql_scalars_t> *s, size_t n_fields)
{
  alloc_res_arr (n_fields);
  amysql_scalars_t &row = s->push_back ();
  row.setsize (n_fields);
  for (size_t i = 0; i < n_fields; i++) {
    res_arr[i] = &row[i];
  }
  adb_status_t res = fetch2 (true);
  if (res != ADB_OK) { s->pop_back (); }
  return res;
}

//-----------------------------------------------------------------------

void
mystmt_t::alloc_res_arr (u_int n)
{
  // reallocate if the old array is not big enough.
  if (res_n < n && res_arr) {
    delete [] res_arr;
    res_arr = NULL;
  }

  res_n = n;
  if (!res_arr)
    res_arr = New mybind_res_t[n];
}

//-----------------------------------------------------------------------

bool
mystmt_t::execute1 (MYSQL_BIND *b, mybind_param_t **arr, u_int n)
{
  struct timeval t1;

  // Set the GMT offset in the global field if necessary, using this
  // thread to do so
  if (_tzc && !_tzc->fetching ()) {
    (void)_tzc->gmt_offset ();
  }

  if (lqt) 
    gettimeofday (&t1, NULL);
  bool rc = execute2 (b, arr, n);
  if (lqt) {
    struct timeval t2;
    gettimeofday (&t2, NULL);
    long sd = (t2.tv_sec - t1.tv_sec) * 1000;
    sd += (t2.tv_usec - t1.tv_usec) / 1000;
    if (sd > long (lqt)) {
      warn << "* Long Query: " << sd << "ms\n";
      warn << "**  " << dump (arr, n) << "\n";
    }
  }
  return rc;
}

//=======================================================================
