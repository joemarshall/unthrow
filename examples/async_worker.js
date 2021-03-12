self.languagePluginUrl = "{{ PYODIDE_BASE_URL }}"

importScripts("pyodide.js")


class CancelSleep
{
    constructor(ms)
    {
        this.p=new Promise((resolve,reject)=>{
          this.sleepTimer=setTimeout(resolve,ms); this.rejectFN=reject;
        });
        this.p.owner=this;
        this.p.cancel=()=>{this.cancel();}
    };

    cancel()
    {
        clearTimeout(this.sleepTimer);
        this.rejectFN();
    };
    
    getPromise()
    {
        return this.p;
    }

    
};

function sleep(ms) {
    
    return new CancelSleep(ms).getPromise();
}

var inCancel=false;
var pyConsole;
var results,state;
var sleeper;
var sleepTimer;
var runCommandID;

function stdout_write(s)
{
    if(!inCancel)
    {
        self.postMessage({type:"stdout",text:s});
    }
}

function stderr_write(s)
{
    if(!inCancel)
    {
        self.postMessage({type:"stderr",text:s});
    }
}


onmessage = async function(e) {
    console.log("MSG:",pyConsole,e);
    await languagePluginLoader;
    const {cmd,arg,id} = e.data;    
    if(cmd =='init')
    {

       await pyodide.runPythonAsync(`
import unthrow
# create hook for time.sleep
import time
time.sleep=lambda t: unthrow.stop({"cmd":"sleep","time":t})

import sys
import js
from pyodide import console


def displayhook(value):
    separator = "\\n[[;orange;]<long output truncated>]\\n"
    _repr = lambda v: console.repr_shorten(v, separator=separator)
    return console.displayhook(value, _repr)

sys.displayhook = displayhook


class PyConsole(console.InteractiveConsole):
    def __init__(self):
        super().__init__(
            persistent_stream_redirection=False,
        )
        self.resume_args=None
        self.resumer=unthrow.Resumer()
        self.resumer.set_interrupt_frequency(50)
        self.cancelled=False
        self.run_source_obj=None
        self.run_code_obj=None

    def clear_cancel(self):
        self.cancelled=False

    def cancel_run(self):
        self.cancelled=True
        self.resetbuffer()
        self.run_code_obj=None
        self.run_source_obj =None

    def run_once(self):
        if self.cancelled:
            self.cancelled=False
            self.finished=True
            return {"done":True,"action":"cancelled"}
        if self.run_source_obj:
            js.console.log("Load packages")
            src=self.run_source_obj
            self.run_source_obj=None
            return {"done":False,"action":"await","obj":console._load_packages_from_imports(src)}
        elif self.run_code_obj:
            js.console.log("runcodeobject")
            with self.stdstreams_redirections():
                try:
                    if not self.resumer.run_once(exec,[self.run_code_obj,self.locals]):
                        self.resume_args=self.resumer.resume_params
                        self.flush_all()
                        # need to rerun run_once after handling this action
                        return {"done":False,"action":"resume","args":self.resume_args}
                except BaseException:
                    self.showtraceback()
                # in CPython's REPL, flush is performed
                # by input(prompt) at each new prompt ;
                # since we are not using input, we force
                # flushing here
                self.flush_all()
                self.run_code_obj=None
                self.run_source_obj =None

            return {"done":True}


    def runcode(self, code):
        #  we no longer actually run code in here, 
        # we store it here and then repeatedly run 
        js.console.log("runcode")
        source = "\\n".join(self.buffer)
        self.run_code_obj=code
        self.run_source_obj = source

    def banner(self):
        return f"Welcome to the Pyodide terminal emulator 🐍\\n{super().banner()}"

__pc=PyConsole()            
        `);
        pyConsole=pyodide.globals.get("__pc");
        pyConsole.stdout_callback = stdout_write
        pyConsole.stderr_callback = stderr_write

        console.log("Made pyconsole",pyConsole);
        self.postMessage({id:id,type:"response",results:true});
    }
    if (cmd =='run')
    {
        await runPythonInLoop(id,arg); 
    }
    if(cmd=="banner")
    {
        banner=pyodide.runPython("__pc.banner()");
        self.postMessage({id:id,type:"response",results:banner});
    }
    if(cmd=="push_and_run")
    {        
        needsMore=pyConsole.push(arg);
        if (needsMore)
        {
            self.postMessage({id:id,type:"response",needsMore:true});
        }else
        {
            retVal=pyodide.runPython("__pc.clear_cancel()")
            runCommandID=id;
            while(true)
            {
                console.log("Run once",arg)
                var retVal;
                var resumeArg;
                retVal=pyodide.runPython("__pc.run_once()")
                if(!retVal || !retVal.get)
                {
                    self.postMessage({id:id,type:"response",failed:true});
                    return
                }                
                if (retVal.get("done")==true)
                {
                    self.postMessage({id:id,type:"response",results:true});
                    return;
                }else
                {
                    const action=retVal.get("action");
                    console.log("Resume loop",action);
                    if(action==="await")
                    {
                        await retVal.get("object");
                    }else if(action=="resume")
                    { 
                        args=retVal.get("args"); 
                        console.log(args) 
                        if(args.get("interrupt")) {
                            console.log("I")
                            sleeper=sleep(0)
                            try
                            {
                                await sleeper;                            
                            }catch(e)
                            {
                                self.postMessage({id:id,type:"response",cancelled:true});    
                                sleeper=null;
                                return;
                            }
                            sleeper=null;
                        }else if(args.get("cmd")=="sleep")
                        {
                            sleeper=sleep(args.get("time")*1000);
                            try
                            {
                                await sleeper;
                            }catch(e)
                            {
                                self.postMessage({id:id,type:"response",cancelled:true});    
                                sleeper=null;
                                return;
                            }
                            sleeper=null;
                        }
                    }
                }
            }
        }
    }
    if(cmd=="abort")
    {
        incancel=true;
        pyodide.runPython("__pc.cancel_run()"); 
        if(sleeper) {
            console.log(sleeper);
            sleeper.cancel();
            sleeper=null;
            self.postMessage({id:id,type:"response",results:true});
        }
        self.postMessage({id:id,type:"response",results:true});
        incancel=false;
    }
    if(cmd=="tab_complete")
    {
        self.postMessage({id:id,type:"response",results:pyConsole.complete()});
    }
}



