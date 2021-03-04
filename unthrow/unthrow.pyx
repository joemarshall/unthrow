#cython: language_level=3
from cpython.object cimport PyObject,Py_SIZE
from cpython.ref cimport Py_XINCREF,Py_XDECREF
from libc.string cimport memcpy 
from cpython cimport array
import array


import sys,inspect,dis

__skip_stop=False

cdef extern from "Python.h":

    cdef char* PyBytes_AsString(PyObject *o)
    cdef PyObject* PyBytes_FromStringAndSize(const char *v, Py_ssize_t len)
    cdef Py_ssize_t PyObject_Length(PyObject *o)

cdef extern from "frameobject.h":
    ctypedef struct PyTryBlock:
        pass


    cdef enum:
        CO_MAXBLOCKS

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
        PyTryBlock f_blockstack[CO_MAXBLOCKS]
        int f_iblock


    ctypedef _frame PyFrameObject

    cdef PyFrameObject* PyEval_GetFrame()
    cdef void PyFrame_FastToLocals(PyFrameObject* frame)

cdef get_stack_pos_after(object code,int target,logger):
    stack_levels={}
    jump_levels={}
    cur_stack=0
    for i in dis.get_instructions(code):
        offset=i.offset
        argval=i.argval
        arg=i.arg
        opcode=i.opcode
        if offset in jump_levels:
            cur_stack=jump_levels[offset]
        no_jump=dis.stack_effect(opcode,arg,jump=False)        
        if opcode in dis.hasjabs or opcode in dis.hasjrel:
            # a jump - mark the stack level at jump target
            yes_jump=dis.stack_effect(opcode,arg,jump=True)        
            if not argval in jump_levels:
                jump_levels[argval]=cur_stack+yes_jump
        cur_stack+=no_jump
        stack_levels[offset]=cur_stack
        logger(offset,i.opname,argval,cur_stack)
    return stack_levels[target]

def _copy_frame_object(source_frame,target_frame=None,logger=lambda *x:None,inc_references=True):
    cdef PyFrameObject* source_frame_addr=<PyFrameObject*>source_frame
    cdef PyFrameObject* target_frame_addr=NULL
    cdef array.array ra;
    if inspect.isframe(source_frame):        
        source_frame_addr=<PyFrameObject*>source_frame
        PyFrame_FastToLocals(source_frame_addr)
    else:
        ra=source_frame
        source_frame_addr=<PyFrameObject*>ra.data.as_chars
    if target_frame!=None:
        target_frame_addr=<PyFrameObject*>target_frame

    ret_array=None
    # copy value, block stacks and locals / globals etc. from a frame
    # which is live (i.e. not after exception has been thrown, which 
    # kills stacks and frees things) into a new frame object which has stack set correctly etc.
    
    # find current stack size of stack at this point
    # n.b. we can't rely on the stack to be in the frame object
    # because it is kept in a local variable in evaluation loop
    logger((<object>source_frame_addr[0].f_code))
    max_stacksize=(<object>source_frame_addr[0].f_code).co_stacksize

    # if no target frame passed, make a placeholder buffer to hold the 
    # values that are in the frame - this is not really a frame in python
    # just holds the references we need to keep for us
    cdef array.array byte_array_template = array.array('b', [0])
    if target_frame_addr==NULL:                
        frame_size=(Py_SIZE(<object>source_frame_addr)-1)*sizeof(PyObject*) + sizeof(PyFrameObject)
        ra=array.clone(byte_array_template,frame_size,zero=True)
        ret_array=ra
        target_frame_addr=<PyFrameObject*>ra.data.as_chars
        target_frame_addr[0].f_code=source_frame_addr[0].f_code
        if inc_references:
            Py_XINCREF(target_frame_addr[0].f_code)
        logger("SAVING FRAME:",<object>target_frame_addr[0].f_code)

    target_frame_addr[0].f_lasti=source_frame_addr[0].f_lasti

    max_stacksize=(<object>target_frame_addr[0].f_code).co_stacksize
    our_stacksize=get_stack_pos_after(<object>source_frame_addr[0].f_code,target_frame_addr[0].f_lasti-2,logger)
    logger("stackSize:",our_stacksize,target_frame_addr[0].f_lasti)

    # copy value stack and local objects themselves across
    # incrementing references on anything that needs incrementing

    if  <int>source_frame_addr[0].f_locals==0 or  source_frame_addr[0].f_locals== source_frame_addr[0].f_globals:
        new_locals_len=0
    else:
        new_locals_len=len(<object>(source_frame_addr[0].f_locals) )#<object>(source_frame_addr[0].f_locals));
    old_locals_len=0
    if target_frame!=None:
        old_locals_len=len(target_frame.f_locals)
    logger("NL:",new_locals_len,"OL:",old_locals_len)
    for c in range(our_stacksize + new_locals_len ):
        if c<old_locals_len: 
            #unref old locals (we know we're always at the start of a method so no old stack)
            Py_XDECREF((target_frame_addr[0].f_localsplus[c]))
        target_frame_addr[0].f_localsplus[c]=source_frame_addr[0].f_localsplus[c]
        if inc_references:
            Py_XINCREF((target_frame_addr[0].f_localsplus[c]))
        if <int>target_frame_addr[0].f_localsplus[c]!=0:
            logger("STACK+LOCALS:",c,"=",<object>target_frame_addr[0].f_localsplus[c])
        else:
            logger("STACK+LOCALS:",c,"= NULL")
    # update stack top and size
    target_frame_addr[0].f_valuestack=&target_frame_addr[0].f_localsplus[new_locals_len]
    target_frame_addr[0].f_stacktop=&target_frame_addr[0].f_valuestack[our_stacksize]
    

    # copy local symbol table
    _copytable(&(target_frame_addr[0].f_locals),&(source_frame_addr[0].f_locals),increfs=inc_references,decrefs=not inc_references)

    # copy global symbol table
    _copytable(&(target_frame_addr[0].f_globals),&(source_frame_addr[0].f_globals),increfs=inc_references,decrefs=not inc_references)

    # copy builtins
    _copytable(&(target_frame_addr[0].f_builtins),&(source_frame_addr[0].f_builtins),increfs=inc_references,decrefs=not inc_references)
    
    # copy the block stack
    target_frame_addr[0].f_iblock=source_frame_addr[0].f_iblock
    memcpy(target_frame_addr[0].f_blockstack,source_frame_addr[0].f_blockstack,sizeof(PyTryBlock)*CO_MAXBLOCKS);
    return ret_array        


# copy a table and correctly inc and dec the references
# nb. we use the temp just in case they are pointers to the same object
# which we don't want to unref too much
cdef void _copytable(PyObject **destTable,PyObject **fromTable,decrefs=False,increfs=False):
    cdef PyObject* temp
    temp = destTable[0]
    destTable[0]=fromTable[0]
    if increfs:
        Py_XINCREF((destTable[0]))
    if decrefs:
        Py_XDECREF(temp)

class ResumableException(Exception):
    def __init__(self,message):
        Exception.__init__(self,message)
        # store locals and stack for all the things, while we're still in a call, before exception is thrown 
        # and calling stack objects are dereferenced
        self._save_stack()

    def _save_stack(self):
        self.savedFrames=[]
        st=inspect.stack()
        for frameinfo in st:
            self.savedFrames.append((frameinfo.frame.f_code,_copy_frame_object(frameinfo.frame,inc_references=True)))
#        print(self.savedFrames)


    def resume(self):
        global __skip_stop
        __skip_stop=True
        st=inspect.stack()
        for frameinfo in reversed(st):
            if self.savedFrames[-1][0]==frameinfo.frame.f_code:
                self.savedFrames=self.savedFrames[:-1]
        sys.settrace(self._calltrace)

    def _calltrace(self,frame,event,arg):
        if len(self.savedFrames)>0:
            return self._resumefn
        return None

    def _resumefn(self,frame,event,arg):
        if len(self.savedFrames)>0:
            resumeCode,resumeFrame=self.savedFrames[-1]
#            print(resumeCode,frame)
            if frame.f_code==resumeCode:
                #print("MATCH FRAME:",frame,resumeCode)
                self.savedFrames=self.savedFrames[:-1]
                if len(self.savedFrames)==0:
                    _copy_frame_object(resumeFrame,frame,inc_references=False)
                    sys.settrace(None)
                else:
                    _copy_frame_object(resumeFrame,frame,inc_references=False)

# this is a c function so it doesn't get traced into
def stop(msg):
    global __skip_stop
    if __skip_stop:
        print("RESUMING")
        __skip_stop=False
    else:
        print("STOPPING NOW")
        rex=ResumableException(msg)
        raise rex

    




