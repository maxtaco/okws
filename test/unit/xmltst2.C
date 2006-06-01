// -*-c++-*-
/* $Id: okcgi.h 1682 2006-04-26 19:17:22Z max $ */

#include "okxml.h"
#include "abuf_pipe.h"
#include "okxmlparse.h"
#include "okxmlwrap.h"
#include "tame.h"

int
main (int argc, char *argv[])
{
  zbuf z;
  strbuf b;
  ptr<xml_element_t> e (xml_method_response_t::alloc ());
  xml_wrap_t w (e);


  w[0][0] = "hi";
  w[0][1] = 3;
  w[0][2][0] = "bye";
  w[0][2][1] = 10;
  w[0][3] = "yo";
  w[1]("a") = "aa";
  w[1]("b") = "bb";
  w[2]("foo")("bar")("this")("that")[4] = 4;
  w[2]("foo")("biz")[5] = 10;

  xml_const_wrap_t w2 (e);
  warn << "i=" << int (w2[2]("foo")("biz")[5]) << "\n";

  e->dump (z);
  z << "-------------------------------\n";
  w = xml_fault_wrap_t (10, "Error code #@#$ = 10");
  e->dump (z);

  z.to_strbuf (&b, false);
  b.tosuio ()->output (1);


}
