// -*-c++-*-
#include "pub3func.h"

//-----------------------------------------------------------------------

bool
pub3::for_t::add (ptr<arglist_t> l)
{
  bool ret = true;
  if (_iter || 
      !l || 
      l->size () != 2 ||
      !(_iter = ((*l)[0])->eval ()) ||
      !(_arr = ((*l)[1])->eval ())) {
    PWARN ("pub takes 2 arguments (formal variable and array)\n");
    ret = false;
  }
  return ret;
}

//-----------------------------------------------------------------------

void
pub3::for_t::output (output_t *o, penv_t *e) const
{
}

//-----------------------------------------------------------------------

tamed void
pub3::for_t::publish (pub2_iface_t *iface, output_t *o, penv_t *e,
		      xpub_status_cb_t callercv) const
{
  tvars {
    const parr_mixed_t *a;
    const pval_t *v;
    ptr<const pval_t> hold;
    bool ok (false);
    aarr_t frame;
    size_t i, len;
    ptr<pval_t> row;
    ptr<aarr_arg_t> row_aarr;
    xpub_status_t res (XPUB_STATUS_OK);
    size_t frame_pointer;
  }

  if (!(v = e->lookup (_arr, false)) || !(hold = mkref (v))) {
    strbuf b ("for: cannot find iterable vector (%s)\n", _arr.cstr ());
    o->output_err (e, b, lineno);
  } else if (!(a = v->to_mixed_arr ())) {
    strbuf b ("for: given value is not iterable vector (%s)\n", _arr.cstr ());
    o->output_err (e, b, lineno);
  } else {
    ok = true;
    len = a->size ();

    frame_pointer = e->size ();
    e->push (&frame);

    for (i = 0; i < len; i++) {
      if (!(row = (*a)[i])) {
	strbuf b ("for: row %zu is undefined!\n", i);
	o->output_err (e, b, lineno);
      } else if (!(row_aarr = row->to_aarr ())) {
	strbuf b ("for: row %zu is not an associative array!\n", i);
	o->output_err (e, b, lineno);
      } else if (_env) {
	row_aarr->replace ("count", int64_t (len));
	row_aarr->replace ("iter", int64_t (i));
	row_aarr->replace ("last", int64_t (len - 1 == i));
	row_aarr->replace ("odd", int64_t (i % 2));
	row_aarr->replace ("even", 1 - int64_t (i % 2));
	frame.replace (_iter, row_aarr);

	twait { _env->publish (iface, o, e, mkevent (res)); }
      }
    }
    e->resize (frame_pointer);
  }
  
  (*callercv) (res);
}

//-----------------------------------------------------------------------

bool
pub3::for_t::publish_nonblock (pub2_iface_t *i, output_t *o, penv_t *e) const
{
  return false;
}

//-----------------------------------------------------------------------

bool
pub3::cond_t::publish_nonblock (pub2_iface_t *i, output_t *o, penv_t *e) const
{
  return false;
}

//-----------------------------------------------------------------------

tamed void
pub3::cond_t::publish (pub2_iface_t *iface, output_t *o, penv_t *e,
		      xpub_status_cb_t callercv) const
{
  tvars {
    xpub_status_t res (XPUB_STATUS_OK);
  }
  (*callercv) (res);
}

//-----------------------------------------------------------------------

void
pub3::cond_t::output (output_t *o, penv_t *e) const
{
}

//-----------------------------------------------------------------------

namespace pub3 {

  ptr<runtime_fn_t>
  runtime_fn_t::alloc (const str &s, ptr<expr_list_t> l, str *err)
  {
    return NULL;
  }

};

//-----------------------------------------------------------------------