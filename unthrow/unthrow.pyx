#cython: language_level=3
from cpython.object cimport PyObject,Py_SIZE
from cpython.ref cimport Py_INCREF,Py_XDECREF,Py_XINCREF
from libc.string cimport memcpy 
from cpython cimport array
import array
import collections

import sys,inspect,dis

_SavedFrame=collections.namedtuple("_framestore",['locals_and_stack','lasti', 'code','block_stack','locals_map'],module=__name__)

class _PythonNULL(object):
    pass

__skip_stop=False

cdef extern from "Python.h":
    cdef int PyCompile_OpcodeStackEffectWithJump(int,int,int)
    cdef char* PyBytes_AsString(PyObject *o)
    cdef PyObject* PyBytes_FromStringAndSize(const char *v, Py_ssize_t len)
    cdef Py_ssize_t PyObject_Length(PyObject *o)
    cdef PyObject* PyDict_GetItem(PyObject*,PyObject*)

cdef extern from "frameobject.h":
    ctypedef struct PyTryBlock:
        int b_type                
        int b_handler             
        int b_level  


    cdef struct _frame:
        PyObject* f_code
        int f_lasti
        char f_executing
        PyObject *f_locals
        PyObject *f_globals
        PyObject *f_builtins

        PyObject **f_stacktop
        PyObject **f_valuestack
        PyObject **f_localsplus
        PyTryBlock f_blockstack[1] # this is actually sized by a constant, but cython 
                                   # doesn't redeclare it so we can just put 1 in 
        int f_iblock


    ctypedef _frame PyFrameObject

    cdef PyFrameObject* PyEval_GetFrame()
    cdef void PyFrame_FastToLocals(PyFrameObject* frame)

cdef get_stack_pos_after(object code,int target):
    cdef int no_jump
    cdef int yes_jump
    cdef int opcode
    cdef int arg
    stack_levels={}
    jump_levels={}
    cur_stack=0
    for i in dis.get_instructions(code):
        offset=i.offset
        argval=i.argval
        if i.arg:
            arg=int(i.arg)
        else:
            arg=0
        opcode=int(i.opcode)
        if offset in jump_levels:
            cur_stack=jump_levels[offset]
        no_jump=PyCompile_OpcodeStackEffectWithJump(opcode,arg,0)
#dis.stack_effect(opcode,arg,jump=False)        
        if opcode in dis.hasjabs or opcode in dis.hasjrel:
            # a jump - mark the stack level at jump target
            yes_jump=PyCompile_OpcodeStackEffectWithJump(opcode,arg,1)
#            yes_jump=dis.stack_effect(opcode,arg,jump=True)        
            if not argval in jump_levels:
                jump_levels[argval]=cur_stack+yes_jump
        cur_stack+=no_jump
        stack_levels[offset]=cur_stack
      #  print(offset,i.opname,argval,cur_stack)
    return stack_levels[target]


cdef object save_frame(PyFrameObject* source_frame):
    cdef PyObject *localPtr;
    PyFrame_FastToLocals(source_frame)
    blockstack=[]
    # last instruction called
    lasti=source_frame.f_lasti
    # get our value stack size from the code instructions
    our_stacksize=get_stack_pos_after(<object>source_frame.f_code,lasti-2)
    our_localsize=<int>(source_frame.f_valuestack-source_frame.f_localsplus);
    code_obj=(<object>source_frame).f_code.co_code    
    # grab everything off the locals and value stack
    valuestack=[]
    for c in range(our_stacksize+our_localsize):
        if <int>source_frame.f_localsplus[c] ==0:
            valuestack.append(_PythonNULL())
        else:
            valuestack.append(<object>source_frame.f_localsplus[c])
    blockstack=[]
    for c in range(source_frame.f_iblock):
        blockstack.append(source_frame.f_blockstack[c])
    locals_map={}
    if source_frame.f_locals!=source_frame.f_globals:
        locals_map=(<object>source_frame).f_locals
    return _SavedFrame(locals_and_stack=valuestack,code=code_obj,lasti=lasti,block_stack=blockstack,locals_map=locals_map)

cdef void restore_saved_frame(PyFrameObject* target_frame,saved_frame: _SavedFrame):
    # last instruction    
    target_frame.f_lasti=saved_frame.lasti
    # check code is the same
    if (<object>target_frame).f_code.co_code!=saved_frame.code:
        print("Trying to restore wrong frame")
        return
    # restore locals and stack
    for c,x in enumerate(saved_frame.locals_and_stack):
        if type(x)==_PythonNULL:
            target_frame.f_localsplus[c]=NULL
        else:
            target_frame.f_localsplus[c]=<PyObject*>x
            Py_INCREF(x)
    target_frame.f_stacktop=&target_frame.f_localsplus[len(saved_frame.locals_and_stack)]

    # restore block stack
    for c,x in enumerate(saved_frame.block_stack):
        target_frame.f_blockstack[c]=x
    target_frame.f_iblock=len(saved_frame.block_stack)
    # restore local symbols
    target_frame.f_locals=<PyObject*>(saved_frame.locals_map)
    Py_XINCREF(target_frame.f_locals)


class ResumableException(Exception):
    def __init__(self,parameter):
        Exception.__init__(self,str(parameter))
        # store locals and stack for all the things, while we're still in a call, before exception is thrown 
        # and calling stack objects are dereferenced
        self._save_stack()
        self.parameter=parameter


    def _save_stack(self):
        self.savedFrames=[]
        st=inspect.stack()
        for frameinfo in st:
            self.savedFrames.append(save_frame(<PyFrameObject*>(frameinfo.frame)))

    def resume(self):
        global __skip_stop
        __skip_stop=True
        st=inspect.stack()
        for frameinfo in reversed(st):
            if self.savedFrames[-1].code==frameinfo.frame.f_code.co_code:
                self.savedFrames=self.savedFrames[:-1]
        sys.settrace(self._calltrace)

    def _calltrace(self,frame,event,arg):
        if len(self.savedFrames)>0:
            return self._resumefn
        return None

    def _resumefn(self,frame,event,arg):
        if len(self.savedFrames)>0:
            resumeFrame=self.savedFrames[-1]
            if frame.f_code.co_code==resumeFrame.code:
#                print("MATCH FRAME:",frame,resumeFrame)
                self.savedFrames=self.savedFrames[:-1]
                restore_saved_frame(<PyFrameObject*>frame,resumeFrame)
                if len(self.savedFrames)==0:
                    sys.settrace(None)

# this is a c function so it doesn't get traced into
def stop(msg):
    global __skip_stop
    if __skip_stop:
#        print("RESUMING")
        __skip_stop=False
    else:
#        print("STOPPING NOW")
        rex=ResumableException(msg)
        raise rex

    




