import unthrow
import inspect
import traceback
import sys
import dis

print("HERE 1")

fullTrace=[]

class ResumeException(Exception):
    pass


def traceFn(frame,event,arg):
    global fullTrace
    if len(fullTrace)>0:
        # resuming - set line on first call entry
        return resumeFn
    else:
        # do call as normal
        return None

def resumeFn(frame,event,arg):
    global fullTrace
#    print(dir(fullTrace[0]))
    if len(fullTrace)>0:
        resumer=fullTrace[0]
        if frame.f_code==resumer.frame.f_code:
            print("MATCH FRAME:",frame,resumer)
            fullTrace=fullTrace[1:]
            if len(fullTrace)==0:
#                print(dis.dis(frame.f_code),resumer.frame.f_locals,resumer.frame.f_lasti,frame.f_lasti)
                unthrow.resumeFrame(resumer.frame,frame,None)
            else:
                unthrow.resumeFrame(resumer.frame,frame,fullTrace[0].frame.f_code)

def exceptionTest():
    unthrow.stop("I'm stopping here")


def mainApp():
    for c in range(10):
        print("L:",c)
        if c==3 or c==5:
            exceptionTest()
    print("END APP")

thisException=None
while True:
    print("DOING SOMETHING AT TOP LEVEL")
    try:
        if thisException:
            thisException.resume()
        mainApp()
        print("DONE")
        break
    except unthrow.ResumableException as e:        
        thisException=e



