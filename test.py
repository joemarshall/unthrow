import unthrow
import inspect
import traceback
import sys
import dis

print("HERE 1")

fullTrace=[]


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
        print("Top level:",e.parameter)



