# Unthrow package for python 3.8

This defines a function stop(message), which saves the stack state and then throws an unthrow.ResumableException.

ResumableException has a method resume() which restores the stack state to where stop was called. It should work with loops, with statements and other block things. It probably won't work with call stacks including c code.

This allows you to stop and start the interpreter from deep in the stack, to do stuff in javascript or whatever is running the interpreter..

3.9 stores stack level as a number not a pointer, it will need this minor change to work on 3.9



