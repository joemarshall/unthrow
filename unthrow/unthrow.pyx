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
    logger(code,target)
    stackLevels={}
    jumpLevels={}
    curStack=0
    for i in dis.get_instructions(code):
        offset=i.offset
        argval=i.argval
        arg=i.arg
        opcode=i.opcode
        if offset in jumpLevels:
            curStack=jumpLevels[offset]
        noJump=dis.stack_effect(opcode,arg,jump=False)        
        if opcode in dis.hasjabs or opcode in dis.hasjrel:
            # a jump - mark the stack level at jump target
            yesJump=dis.stack_effect(opcode,arg,jump=True)        
            if not argval in jumpLevels:
                jumpLevels[argval]=curStack+yesJump
            logger("JT:",argval,jumpLevels[argval])
        curStack+=noJump
        stackLevels[offset]=curStack
        logger(offset,i.opname,argval,curStack)
    return stackLevels[target]

def _copyFrameObject(frameToCopy,thisFrame=None,logger=lambda *x:None):
    cdef PyFrameObject* frameToCopyAddr=<PyFrameObject*>frameToCopy
    cdef PyFrameObject* thisFrameAddr=NULL
    cdef array.array ra;
    if inspect.isframe(frameToCopy):        
        frameToCopyAddr=<PyFrameObject*>frameToCopy
        PyFrame_FastToLocals(frameToCopyAddr)
    else:
        ra=frameToCopy
        frameToCopyAddr=<PyFrameObject*>ra.data.as_chars
    if thisFrame!=None:
        thisFrameAddr=<PyFrameObject*>thisFrame

#    logger(frameToCopy,<object>(frameToCopyAddr[0].f_locals))
    retArray=None
    # copy value, block stacks and locals / globals etc. from a frame
    # which is live (i.e. not after exception has been thrown, which 
    # kills stacks and frees things) into a new frame object which has stack set correctly etc.
    
    # find current stack size of stack at this point
    # n.b. we can't rely on the stack to be in the frame object
    # because it is kept in a local variable in evaluation loop
    logger("HMM")
    logger((<object>frameToCopyAddr[0].f_code))
    logger("BMM")
    max_stacksize=(<object>frameToCopyAddr[0].f_code).co_stacksize

    # if no target frame passed, make a placeholder buffer to hold the 
    # values that are in the frame - this is not really a frame in python
    # just holds the references we need to keep for us
    cdef array.array byte_array_template = array.array('b', [0])
    logger(<int>thisFrameAddr)
    if thisFrameAddr==NULL:                
        frameSize=(Py_SIZE(<object>frameToCopyAddr)-1)*sizeof(PyObject*) + sizeof(PyFrameObject)
        logger("WOO")
        ra=array.clone(byte_array_template,frameSize,zero=True)
        retArray=ra
        thisFrameAddr=<PyFrameObject*>ra.data.as_chars
        thisFrameAddr[0].f_code=frameToCopyAddr[0].f_code
        Py_XINCREF(thisFrameAddr[0].f_code)
        logger("SAVING FRAME:",<object>thisFrameAddr[0].f_code)

    thisFrameAddr[0].f_lasti=frameToCopyAddr[0].f_lasti
    logger("BOSH")

    max_stacksize=(<object>thisFrameAddr[0].f_code).co_stacksize
    our_stacksize=get_stack_pos_after(<object>frameToCopyAddr[0].f_code,thisFrameAddr[0].f_lasti-2,logger)
    logger("stackSize:",our_stacksize,thisFrameAddr[0].f_lasti)

    # copy value stack and local objects themselves across
    # incrementing references on anything that needs incrementing

    if  <int>frameToCopyAddr[0].f_locals==0 or  frameToCopyAddr[0].f_locals== frameToCopyAddr[0].f_globals:
        newLocalsLen=0
    else:
        newLocalsLen=len(<object>(frameToCopyAddr[0].f_locals) )#<object>(frameToCopyAddr[0].f_locals));
    oldLocalsLen=0
    if thisFrame!=None:
        oldLocalsLen=len(thisFrame.f_locals)
    logger("NL:",newLocalsLen,"OL:",oldLocalsLen)
    for c in range(our_stacksize + newLocalsLen ):
        if c<oldLocalsLen: 
            #unref old locals (we know we're always at the start of a method so no old stack)
            Py_XDECREF((thisFrameAddr[0].f_localsplus[c]))
        thisFrameAddr[0].f_localsplus[c]=frameToCopyAddr[0].f_localsplus[c]
        Py_XINCREF((thisFrameAddr[0].f_localsplus[c]))
        if <int>thisFrameAddr[0].f_localsplus[c]!=0:
            logger("STACK+LOCALS:",c,"=",<object>thisFrameAddr[0].f_localsplus[c])
        else:
            logger("STACK+LOCALS:",c,"= NULL")
    logger("YAY")
    # update stack top and size
    thisFrameAddr[0].f_valuestack=&thisFrameAddr[0].f_localsplus[newLocalsLen]
    thisFrameAddr[0].f_stacktop=&thisFrameAddr[0].f_valuestack[our_stacksize]
    logger("BOO")
    

    # copy local symbol table
    _copytable(&(thisFrameAddr[0].f_locals),&(frameToCopyAddr[0].f_locals))
    logger("WAH")

    # copy global symbol table
    _copytable(&(thisFrameAddr[0].f_globals),&(frameToCopyAddr[0].f_globals))

    # copy builtins
    _copytable(&(thisFrameAddr[0].f_builtins),&(frameToCopyAddr[0].f_builtins))
    
    # copy the block stack
    thisFrameAddr[0].f_iblock=frameToCopyAddr[0].f_iblock
    memcpy(thisFrameAddr[0].f_blockstack,frameToCopyAddr[0].f_blockstack,sizeof(PyTryBlock)*CO_MAXBLOCKS);
    return retArray        


# copy a table and correctly inc and dec the references
# nb. we use the temp just in case they are pointers to the same object
# which we don't want to unref too much
cdef void _copytable(PyObject **destTable,PyObject **fromTable,decrefs=False):
    cdef PyObject* temp
    temp = destTable[0]
    destTable[0]=fromTable[0]
    Py_XINCREF((destTable[0]))
    return
    if decrefs:
        Py_XDECREF(temp)

class ResumableException(Exception):
    def __init__(self,message):
        Exception.__init__(self,message)
        # store locals and stack for all the things, while we're still in a call, before exception is thrown 
        # and calling stack objects are dereferenced
        self._saveStack()

    def _saveStack(self):
        self.savedFrames=[]
        st=inspect.stack()
        for frameinfo in st:
            self.savedFrames.append((frameinfo.frame.f_code,_copyFrameObject(frameinfo.frame)))
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
                    _copyFrameObject(resumeFrame,frame)
                    sys.settrace(None)
                else:
                    _copyFrameObject(resumeFrame,frame)

# this is a c function so it doesn't get traced into
def stop():
    global __skip_stop
    if __skip_stop:
        print("RESUMING")
        __skip_stop=False
    else:
        print("STOPPING NOW")
        rex=ResumableException("BOOM")
        raise rex

    




