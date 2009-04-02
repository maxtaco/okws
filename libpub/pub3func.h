// -*-c++-*-
/* $Id: parr.h 2784 2007-04-20 16:32:00Z max $ */


#ifndef _LIBPUB_PUB3FUNC_H_
#define _LIBPUB_PUB3FUNC_H_

#include "pub.h"
#include "parr.h"
#include "pub3expr.h"

namespace pub3 {

  //-----------------------------------------------------------------------

  class for_t : public pfile_func_t {
  public:
    for_t (int l) : pfile_func_t (l) {}
    for_t (const xpub3_for_t &x);
    bool to_xdr (xpub_obj_t *x) const;
    bool add (ptr<arglist_t> l) { return false; }
    bool add (ptr<expr_list_t> l);
    bool add_env (ptr<nested_env_t> e) { _env = e; return true; }
    bool add_empty (ptr<nested_env_t> e) { _empty = e; return true; }
    const char *get_obj_name () const { return "pub3::for_t"; }
    virtual void publish (pub2_iface_t *, output_t *, penv_t *, 
			  xpub_status_cb_t , CLOSURE) const;
    bool publish_nonblock (pub2_iface_t *, output_t *, penv_t *) const;
    void output (output_t *o, penv_t *e) const;
  protected:
  private:
    str _iter;
    ptr<expr_t> _arr;
    ptr<nested_env_t> _env;
    ptr<nested_env_t> _empty;
  };
  
  //-----------------------------------------------------------------------

  class include_t : public pfile_func_t {
  public:
    include_t (int l) : pfile_func_t (l) {}
    include_t (const xpub3_include_t &x);
    bool to_xdr (xpub_obj_t *x) const;
    bool add (ptr<arglist_t> l) { return false; }
    bool add (ptr<expr_list_t> l);
    const char *get_obj_name () const { return "pub3::include_t"; }
    virtual void publish (pub2_iface_t *, output_t *, penv_t *,
			  xpub_status_cb_t, CLOSURE) const;
    bool publish_nonblock (pub2_iface_t *, output_t *, penv_t *) const;
    void output (output_t *o, penv_t *e) const;
  protected:
    ptr<expr_t> _file;
    ptr<expr_t> _dict;
  };

  //-----------------------------------------------------------------------

  class cond_clause_t {
  public:
    cond_clause_t (int l) : _lineno (l) {}
    cond_clause_t (const xpub3_cond_clause_t &x);

    static ptr<cond_clause_t> alloc (int l) 
    { return New refcounted<cond_clause_t> (l); }

    void add_expr (ptr<expr_t> e) { _expr = e; }
    void add_env (ptr<nested_env_t> e) { _env = e; }

    bool to_xdr (xpub3_cond_clause_t *x) const;

    ptr<const expr_t> expr () const { return _expr; }
    ptr<nested_env_t> env () const { return _env; }

  private:
    int _lineno;
    ptr<expr_t> _expr;
    ptr<nested_env_t> _env;
  };

  //-----------------------------------------------------------------------

  typedef vec<ptr<cond_clause_t> > cond_clause_list_t;

  //-----------------------------------------------------------------------
  
  class cond_t : public pfile_func_t {
  public:
    cond_t (int l) : pfile_func_t (l) {}
    cond_t (const xpub3_cond_t &x);

    void add_clauses (ptr<cond_clause_list_t> c) { _clauses = c; }
    const char *get_obj_name () const { return "pub3::cond_t"; }
    bool to_xdr (xpub_obj_t *x) const;
    void publish (pub2_iface_t *, output_t *, penv_t *, 
		  xpub_status_cb_t , CLOSURE) const;
    bool publish_nonblock (pub2_iface_t *, output_t *, penv_t *) const;
    void output (output_t *o, penv_t *e) const;
    bool add (ptr<arglist_t> al) { return false; }
  private:
    ptr<cond_clause_list_t> _clauses;
  };

  //-----------------------------------------------------------------------

  class set_func_t : public pfile_set_func_t {
  public:
    set_func_t (int l) : pfile_set_func_t (l) {}
    set_func_t (const xpub_set_func_t &x) : pfile_set_func_t (x) {}
    void output_runtime (output_t *o, penv_t *e) const;
    const char *get_obj_name () const { return "pub3::set_func_t"; }
    bool to_xdr (xpub_obj_t *x) const;
  };

  //-----------------------------------------------------------------------

  class runtime_fn_t : public expr_t {
  public:
    runtime_fn_t (const str &n, ptr<expr_list_t> a, int l) 
      : expr_t (l), _name (n), _arglist (a) {}

    ptr<expr_list_t> args () const { return _arglist; }
    str name () const { return _name; }

    bool to_xdr (xpub3_expr_t *x) const;
    const char *get_obj_name () const { return "pub3::runtime_fn_t"; }

    ptr<const pval_t> eval (eval_t e) const { return NULL; }
    ptr<pval_t> eval_freeze (eval_t e) const { return NULL; }

  protected:
    str _name;
    ptr<expr_list_t> _arglist;
  };

  //-----------------------------------------------------------------------

  class error_fn_t : public runtime_fn_t {
  public:
    error_fn_t (const str &n, ptr<expr_list_t> a, int l, const str &err)
      : runtime_fn_t (n, a, l), _err (err) {}

    ptr<const pval_t> eval (eval_t e) const;
    ptr<pval_t> eval_freeze (eval_t e) const;
    const char *get_obj_name () const { return "pub3::error_fn_t"; }
  protected:
    str _err;
  };

  //-----------------------------------------------------------------------

  //
  // rfn_factory: runtime function factory
  //
  //  allocates runtime functions.  OKWS core supports some of them
  //  but specific okws instances are welcome to support more.  
  //  details still uncertain, but it will most likely involve
  //  local changes to pubd (via dynamic loading?) and also changes
  //  to specific services -- similar to the Apache module system...
  //
  class rfn_factory_t {
  public:
    rfn_factory_t () {}
    virtual ~rfn_factory_t () {}

    virtual ptr<runtime_fn_t>
    alloc (const str &s, ptr<expr_list_t> l, int lineno) = 0;

    ptr<runtime_fn_t> alloc (const xpub3_fn_t &x);

    // Access the singleton runtime function factory; by default
    // it's set to a null factory, but can be explanded any which
    // way.
    static ptr<rfn_factory_t> _curr;
    static void set (ptr<rfn_factory_t> f);
    static ptr<rfn_factory_t> get ();
  };

  //-----------------------------------------------------------------------

  class null_rfn_factory_t : public rfn_factory_t {
  public:
    null_rfn_factory_t  () : rfn_factory_t () {}
    ptr<runtime_fn_t> alloc (const str &s, ptr<expr_list_t> l, int lineno);

  };

  //-----------------------------------------------------------------------
};

#endif /* _LIBPUB_PUB3FUNC_H_ */
