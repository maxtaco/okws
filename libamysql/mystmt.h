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

#include "mystmt_ag.h"

#ifndef _LIBAMYSQL_STMTS_H
#define _LIBAMYSQL_STMTS_H

class sth_parsed_t : public mystmt_t 
{
public:
  sth_parsed_t (MYSQL *m, const str &q, u_int o = 0, tz_corrector_t *t = NULL)
    : mystmt_t (t), mysql (m), qry (q), n_iparam (0), bufs (NULL), opts (o),
      myres (NULL) {}
  ~sth_parsed_t ();
  static ptr<sth_parsed_t> 
  alloc (MYSQL *m, const str &q, u_int o, tz_corrector_t *tzc)
  { return New refcounted<sth_parsed_t> (m, q, o, tzc); }
  bool parse ();
  adb_status_t fetch2 (bool bnd = false);
  str get_last_qry () const { return last_qry; }
  const MYSQL_FIELD *fetch_fields (size_t *n);
  size_t n_rows () const;
  size_t affected_rows () const;
  u_int64_t insert_id ();
protected:
  bool execute2 (MYSQL_BIND *b, mybind_param_t **aarr, u_int n);
  str dump (mybind_param_t **aarr, u_int n);
  str make_query (mybind_param_t **aarr, u_int n);
  
  void dealloc_bufs ();
  void alloc_bufs ();
  void row_to_res (MYSQL_ROW *r, MYSQL_RES *res);
  void clearfetch ();

  MYSQL *mysql;
  const str qry;
  u_int n_iparam;
  vec<str> qry_parts;
  char **bufs;
  u_int *lens;
  u_int opts;
  MYSQL_RES *myres;
  unsigned long *length_arr;
  u_int my_res_n;
  str last_qry;
};

#if defined(HAVE_MYSQL_BIND) && defined(HAVE_MYSQL_BINDFUNCS)
class sth_prepared_t : public mystmt_t 
{
public:
  sth_prepared_t (MYSQL_STMT *s, const str &q, u_int o = 0, 
		  tz_corrector_t *t = NULL) 
    : mystmt_t (t), sth (s), bnds (NULL), qry (q), opts (o) {}
  ~sth_prepared_t ();
  static ptr<sth_prepared_t> 
  alloc (MYSQL_STMT *s, const str &q, u_int o, tz_corrector_t *tzc)
  { return New refcounted<sth_prepared_t> (s, q, o, tzc); }
  adb_status_t fetch2 (bool bnd = false);
  const MYSQL_FIELD *fetch_fields (size_t *n) { return NULL; }
  size_t affected_rows () const;
  u_int64_t insert_id ();
protected:
  bool execute2 (MYSQL_BIND *b, mybind_param_t **aarr, u_int n);
  str dump (mybind_param_t **aarr, u_int n);
  void bind (MYSQL_BIND *b, mybind_param_t **arr, u_int n);
  bool bind_result ();
  void clearfetch ();
  MYSQL_STMT *sth;
  MYSQL_BIND *bnds;
  const str qry;
  u_int opts;
};
#endif


#endif /* _LIBAMYSQL_STMTS_H */
