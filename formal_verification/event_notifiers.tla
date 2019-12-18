------------------- MODULE event_notifiers -----------------------
(*
Formal specification of the event_notifiers datastructure.

It allows a single consumer to be put to sleep and being woken up
by multiple producers so that the consumer is able to consume the incoming messages (steal requests).

This is a companion datastructure to a lock-free MPSC (Multi-Producer Single-Consumer) queue

It is a 2-step algorithm "prepareParking" + "park", that allows the potential sleeper
to send a message in-between to its parent.
The commit phase is aborted when any producer signals an incoming message (in the queue).

There should be no deadlock, i.e. an incoming message being signaled but the consumer stays sleeping
as in the runtime the main thread may be the only one awake and wouldn't be able to awaken its children
in that case.
*)
EXTENDS Integers, TLC, Sequences, FiniteSets

CONSTANTS NumThreads, ConsumerTID, MaxTasks
ASSUME NumThreads > 1
ASSUME ConsumerTID > 0
ASSUME ConsumerTID < NumThreads

\* Threads are organized in an implicit binary tree
\* with Parent at N div 2 and child at 2N+1 and 2N+2 with root at 0
MaxID     == NumThreads-1
ParentTID == ConsumerTID \div 2
producers == (0..MaxID) \ {ConsumerTID, ParentTID}

(* PlusCal options (-termination) *)
(* --algorithm event_notifier

variables
    phase = FALSE;                         \* a binary timestamp
    ticket = FALSE;                        \* a ticket to sleep in a phase
    signaled = FALSE;                      \* a flag for incoming condvar signal

    condVar = FALSE;                       \* Simulate a condition variable
    msgToParent = "None";                  \* Simulate a worksharing request to the parent
    signaledTerminate = FALSE;             \* Simulate a termination task
    tasks \in [ 0..MaxID -> 0..MaxTasks ]; \* Tasks per Worker (up to MaxTasks)

\* Simulate a work-stealing runtime
\* ------------------------------------------------------------

macro oneLessTask(pid) begin
    tasks[pid] := tasks[pid] - 1;
end macro;

procedure mayRequestWork(pid)
    \* Work or Steal
    begin MaySteal:
        if tasks[pid] > 0 then
            Work: oneLessTask(pid);
        else
            \* Steal + execute right away so no increment
            Steal: call notify();
        end if;
RET_WS: return;
end procedure

procedure mayShareWork(pid)
    \* If child is "Waiting", send it some work
    begin MayShare:
            if tasks[pid] > 0 then
Share0:         if msgToParent = "Waiting" then
Share1:            call notify();         \* wakeup the child
Share2:            msgToParent := "None"; \* dequeue the child steal request
TaskShared:        oneLessTask(pid);
                end if;
            end if;
RET_Share:  return;
end procedure;

\* Event notifier being specified
\* ------------------------------------------------------------

procedure prepareParking()
    begin
        NotSignaled:  if ~signaled then
        TakeTicket:     ticket := phase;
                      end if;
        RET_Int:      return;
end procedure

procedure park()
    begin
        NotSignaled2:  if ~signaled then
        StillValid:      if ticket = phase then
        Wait:              await condVar;    \* next line is atomic
                           condVar := FALSE; \* we don't model the spurious wakeups here
                         end if;             \* but they are not a problem anyway
                       end if;
        Reset:         signaled := FALSE;
        RET_Park:      return;
end procedure;

procedure notify()
    variables prevState
    begin
        DontUndoOther: if signaled then
        EarlyExit:        return;
                       end if;
        Notify:        signaled := TRUE;
        InvalidTicket: phase := ~phase;
        Awaken:        condVar := TRUE;
        RET_Notify:    return;
end procedure;

\* Simulate the runtime lifetime
\* ------------------------------------------------------------

process producer \in producers
    begin Coworkers:
        while tasks[self] > 0 do
          call mayRequestWork(self);
        end while;
end process;

process parent = ParentTID
    begin ParentWork:
        either \* The order of work sharing and work stealing is arbitrary
            PMayRW0: call mayRequestWork(ParentTID);
            PMaySW0: call mayShareWork(ParentTID);
        or
            PMaySW1: call mayShareWork(ParentTID);
            PMayRW1: call mayRequestWork(ParentTID);
        end either;
        \* But it will for sure tell the consumer to terminate at one point
    OutOfWork:
        if tasks = [x \in 0..MaxID |-> 0] then
            Terminate0: signaledTerminate := TRUE;
            WakeTerm1:  call notify();
            Drop:       msgToParent := "None";
        else
            StillWork: goto ParentWork;
        end if;
end process;

process consumer = ConsumerTID
    begin ConsumerWork:
          if tasks[ConsumerTID] > 0 then
              FoundWork: oneLessTask(ConsumerTID);
          else
              \* we signal our intent to sleep, tell our parent and then sleep
              Sleeping0: call prepareParking();
              Sleeping1: msgToParent := "Waiting";
              Sleeping2: call park();
          end if;
    isEnding:
          if signaledTerminate then
            \* Received a termination task
              RecvTerminate: skip;
          else
              goto ConsumerWork;
          end if;
end process;

end algorithm; *)
\* BEGIN TRANSLATION
\* Parameter pid of procedure mayRequestWork at line 51 col 26 changed to pid_
CONSTANT defaultInitValue
VARIABLES phase, ticket, signaled, condVar, msgToParent, signaledTerminate, 
          tasks, pc, stack, pid_, pid, prevState

vars == << phase, ticket, signaled, condVar, msgToParent, signaledTerminate, 
           tasks, pc, stack, pid_, pid, prevState >>

ProcSet == (producers) \cup {ParentTID} \cup {ConsumerTID}

Init == (* Global variables *)
        /\ phase = FALSE
        /\ ticket = FALSE
        /\ signaled = FALSE
        /\ condVar = FALSE
        /\ msgToParent = "None"
        /\ signaledTerminate = FALSE
        /\ tasks \in [ 0..MaxID -> 0..MaxTasks ]
        (* Procedure mayRequestWork *)
        /\ pid_ = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure mayShareWork *)
        /\ pid = [ self \in ProcSet |-> defaultInitValue]
        (* Procedure notify *)
        /\ prevState = [ self \in ProcSet |-> defaultInitValue]
        /\ stack = [self \in ProcSet |-> << >>]
        /\ pc = [self \in ProcSet |-> CASE self \in producers -> "Coworkers"
                                        [] self = ParentTID -> "ParentWork"
                                        [] self = ConsumerTID -> "ConsumerWork"]

MaySteal(self) == /\ pc[self] = "MaySteal"
                  /\ IF tasks[pid_[self]] > 0
                        THEN /\ pc' = [pc EXCEPT ![self] = "Work"]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "Steal"]
                  /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                  msgToParent, signaledTerminate, tasks, stack, 
                                  pid_, pid, prevState >>

Work(self) == /\ pc[self] = "Work"
              /\ tasks' = [tasks EXCEPT ![pid_[self]] = tasks[pid_[self]] - 1]
              /\ pc' = [pc EXCEPT ![self] = "RET_WS"]
              /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                              signaledTerminate, stack, pid_, pid, prevState >>

Steal(self) == /\ pc[self] = "Steal"
               /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "notify",
                                                        pc        |->  "RET_WS",
                                                        prevState |->  prevState[self] ] >>
                                                    \o stack[self]]
               /\ prevState' = [prevState EXCEPT ![self] = defaultInitValue]
               /\ pc' = [pc EXCEPT ![self] = "DontUndoOther"]
               /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                               signaledTerminate, tasks, pid_, pid >>

RET_WS(self) == /\ pc[self] = "RET_WS"
                /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                /\ pid_' = [pid_ EXCEPT ![self] = Head(stack[self]).pid_]
                /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                signaledTerminate, tasks, pid, prevState >>

mayRequestWork(self) == MaySteal(self) \/ Work(self) \/ Steal(self)
                           \/ RET_WS(self)

MayShare(self) == /\ pc[self] = "MayShare"
                  /\ IF tasks[pid[self]] > 0
                        THEN /\ pc' = [pc EXCEPT ![self] = "Share0"]
                        ELSE /\ pc' = [pc EXCEPT ![self] = "RET_Share"]
                  /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                  msgToParent, signaledTerminate, tasks, stack, 
                                  pid_, pid, prevState >>

Share0(self) == /\ pc[self] = "Share0"
                /\ IF msgToParent = "Waiting"
                      THEN /\ pc' = [pc EXCEPT ![self] = "Share1"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "RET_Share"]
                /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                signaledTerminate, tasks, stack, pid_, pid, 
                                prevState >>

Share1(self) == /\ pc[self] = "Share1"
                /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "notify",
                                                         pc        |->  "Share2",
                                                         prevState |->  prevState[self] ] >>
                                                     \o stack[self]]
                /\ prevState' = [prevState EXCEPT ![self] = defaultInitValue]
                /\ pc' = [pc EXCEPT ![self] = "DontUndoOther"]
                /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                signaledTerminate, tasks, pid_, pid >>

Share2(self) == /\ pc[self] = "Share2"
                /\ msgToParent' = "None"
                /\ pc' = [pc EXCEPT ![self] = "TaskShared"]
                /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                signaledTerminate, tasks, stack, pid_, pid, 
                                prevState >>

TaskShared(self) == /\ pc[self] = "TaskShared"
                    /\ tasks' = [tasks EXCEPT ![pid[self]] = tasks[pid[self]] - 1]
                    /\ pc' = [pc EXCEPT ![self] = "RET_Share"]
                    /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                    msgToParent, signaledTerminate, stack, 
                                    pid_, pid, prevState >>

RET_Share(self) == /\ pc[self] = "RET_Share"
                   /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                   /\ pid' = [pid EXCEPT ![self] = Head(stack[self]).pid]
                   /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                   /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                   msgToParent, signaledTerminate, tasks, pid_, 
                                   prevState >>

mayShareWork(self) == MayShare(self) \/ Share0(self) \/ Share1(self)
                         \/ Share2(self) \/ TaskShared(self)
                         \/ RET_Share(self)

NotSignaled(self) == /\ pc[self] = "NotSignaled"
                     /\ IF ~signaled
                           THEN /\ pc' = [pc EXCEPT ![self] = "TakeTicket"]
                           ELSE /\ pc' = [pc EXCEPT ![self] = "RET_Int"]
                     /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                     msgToParent, signaledTerminate, tasks, 
                                     stack, pid_, pid, prevState >>

TakeTicket(self) == /\ pc[self] = "TakeTicket"
                    /\ ticket' = phase
                    /\ pc' = [pc EXCEPT ![self] = "RET_Int"]
                    /\ UNCHANGED << phase, signaled, condVar, msgToParent, 
                                    signaledTerminate, tasks, stack, pid_, pid, 
                                    prevState >>

RET_Int(self) == /\ pc[self] = "RET_Int"
                 /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                 /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                 /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                 signaledTerminate, tasks, pid_, pid, 
                                 prevState >>

prepareParking(self) == NotSignaled(self) \/ TakeTicket(self)
                           \/ RET_Int(self)

NotSignaled2(self) == /\ pc[self] = "NotSignaled2"
                      /\ IF ~signaled
                            THEN /\ pc' = [pc EXCEPT ![self] = "StillValid"]
                            ELSE /\ pc' = [pc EXCEPT ![self] = "Reset"]
                      /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                      msgToParent, signaledTerminate, tasks, 
                                      stack, pid_, pid, prevState >>

StillValid(self) == /\ pc[self] = "StillValid"
                    /\ IF ticket = phase
                          THEN /\ pc' = [pc EXCEPT ![self] = "Wait"]
                          ELSE /\ pc' = [pc EXCEPT ![self] = "Reset"]
                    /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                    msgToParent, signaledTerminate, tasks, 
                                    stack, pid_, pid, prevState >>

Wait(self) == /\ pc[self] = "Wait"
              /\ condVar
              /\ condVar' = FALSE
              /\ pc' = [pc EXCEPT ![self] = "Reset"]
              /\ UNCHANGED << phase, ticket, signaled, msgToParent, 
                              signaledTerminate, tasks, stack, pid_, pid, 
                              prevState >>

Reset(self) == /\ pc[self] = "Reset"
               /\ signaled' = FALSE
               /\ pc' = [pc EXCEPT ![self] = "RET_Park"]
               /\ UNCHANGED << phase, ticket, condVar, msgToParent, 
                               signaledTerminate, tasks, stack, pid_, pid, 
                               prevState >>

RET_Park(self) == /\ pc[self] = "RET_Park"
                  /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                  /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                  /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                  msgToParent, signaledTerminate, tasks, pid_, 
                                  pid, prevState >>

park(self) == NotSignaled2(self) \/ StillValid(self) \/ Wait(self)
                 \/ Reset(self) \/ RET_Park(self)

DontUndoOther(self) == /\ pc[self] = "DontUndoOther"
                       /\ IF signaled
                             THEN /\ pc' = [pc EXCEPT ![self] = "EarlyExit"]
                             ELSE /\ pc' = [pc EXCEPT ![self] = "Notify"]
                       /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                       msgToParent, signaledTerminate, tasks, 
                                       stack, pid_, pid, prevState >>

EarlyExit(self) == /\ pc[self] = "EarlyExit"
                   /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                   /\ prevState' = [prevState EXCEPT ![self] = Head(stack[self]).prevState]
                   /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                   /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                   msgToParent, signaledTerminate, tasks, pid_, 
                                   pid >>

Notify(self) == /\ pc[self] = "Notify"
                /\ signaled' = TRUE
                /\ pc' = [pc EXCEPT ![self] = "InvalidTicket"]
                /\ UNCHANGED << phase, ticket, condVar, msgToParent, 
                                signaledTerminate, tasks, stack, pid_, pid, 
                                prevState >>

InvalidTicket(self) == /\ pc[self] = "InvalidTicket"
                       /\ phase' = ~phase
                       /\ pc' = [pc EXCEPT ![self] = "Awaken"]
                       /\ UNCHANGED << ticket, signaled, condVar, msgToParent, 
                                       signaledTerminate, tasks, stack, pid_, 
                                       pid, prevState >>

Awaken(self) == /\ pc[self] = "Awaken"
                /\ condVar' = TRUE
                /\ pc' = [pc EXCEPT ![self] = "RET_Notify"]
                /\ UNCHANGED << phase, ticket, signaled, msgToParent, 
                                signaledTerminate, tasks, stack, pid_, pid, 
                                prevState >>

RET_Notify(self) == /\ pc[self] = "RET_Notify"
                    /\ pc' = [pc EXCEPT ![self] = Head(stack[self]).pc]
                    /\ prevState' = [prevState EXCEPT ![self] = Head(stack[self]).prevState]
                    /\ stack' = [stack EXCEPT ![self] = Tail(stack[self])]
                    /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                    msgToParent, signaledTerminate, tasks, 
                                    pid_, pid >>

notify(self) == DontUndoOther(self) \/ EarlyExit(self) \/ Notify(self)
                   \/ InvalidTicket(self) \/ Awaken(self)
                   \/ RET_Notify(self)

Coworkers(self) == /\ pc[self] = "Coworkers"
                   /\ IF tasks[self] > 0
                         THEN /\ /\ pid_' = [pid_ EXCEPT ![self] = self]
                                 /\ stack' = [stack EXCEPT ![self] = << [ procedure |->  "mayRequestWork",
                                                                          pc        |->  "Coworkers",
                                                                          pid_      |->  pid_[self] ] >>
                                                                      \o stack[self]]
                              /\ pc' = [pc EXCEPT ![self] = "MaySteal"]
                         ELSE /\ pc' = [pc EXCEPT ![self] = "Done"]
                              /\ UNCHANGED << stack, pid_ >>
                   /\ UNCHANGED << phase, ticket, signaled, condVar, 
                                   msgToParent, signaledTerminate, tasks, pid, 
                                   prevState >>

producer(self) == Coworkers(self)

ParentWork == /\ pc[ParentTID] = "ParentWork"
              /\ \/ /\ pc' = [pc EXCEPT ![ParentTID] = "PMayRW0"]
                 \/ /\ pc' = [pc EXCEPT ![ParentTID] = "PMaySW1"]
              /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                              signaledTerminate, tasks, stack, pid_, pid, 
                              prevState >>

PMayRW0 == /\ pc[ParentTID] = "PMayRW0"
           /\ /\ pid_' = [pid_ EXCEPT ![ParentTID] = ParentTID]
              /\ stack' = [stack EXCEPT ![ParentTID] = << [ procedure |->  "mayRequestWork",
                                                            pc        |->  "PMaySW0",
                                                            pid_      |->  pid_[ParentTID] ] >>
                                                        \o stack[ParentTID]]
           /\ pc' = [pc EXCEPT ![ParentTID] = "MaySteal"]
           /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                           signaledTerminate, tasks, pid, prevState >>

PMaySW0 == /\ pc[ParentTID] = "PMaySW0"
           /\ /\ pid' = [pid EXCEPT ![ParentTID] = ParentTID]
              /\ stack' = [stack EXCEPT ![ParentTID] = << [ procedure |->  "mayShareWork",
                                                            pc        |->  "OutOfWork",
                                                            pid       |->  pid[ParentTID] ] >>
                                                        \o stack[ParentTID]]
           /\ pc' = [pc EXCEPT ![ParentTID] = "MayShare"]
           /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                           signaledTerminate, tasks, pid_, prevState >>

PMaySW1 == /\ pc[ParentTID] = "PMaySW1"
           /\ /\ pid' = [pid EXCEPT ![ParentTID] = ParentTID]
              /\ stack' = [stack EXCEPT ![ParentTID] = << [ procedure |->  "mayShareWork",
                                                            pc        |->  "PMayRW1",
                                                            pid       |->  pid[ParentTID] ] >>
                                                        \o stack[ParentTID]]
           /\ pc' = [pc EXCEPT ![ParentTID] = "MayShare"]
           /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                           signaledTerminate, tasks, pid_, prevState >>

PMayRW1 == /\ pc[ParentTID] = "PMayRW1"
           /\ /\ pid_' = [pid_ EXCEPT ![ParentTID] = ParentTID]
              /\ stack' = [stack EXCEPT ![ParentTID] = << [ procedure |->  "mayRequestWork",
                                                            pc        |->  "OutOfWork",
                                                            pid_      |->  pid_[ParentTID] ] >>
                                                        \o stack[ParentTID]]
           /\ pc' = [pc EXCEPT ![ParentTID] = "MaySteal"]
           /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                           signaledTerminate, tasks, pid, prevState >>

OutOfWork == /\ pc[ParentTID] = "OutOfWork"
             /\ IF tasks = [x \in 0..MaxID |-> 0]
                   THEN /\ pc' = [pc EXCEPT ![ParentTID] = "Terminate0"]
                   ELSE /\ pc' = [pc EXCEPT ![ParentTID] = "StillWork"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, tasks, stack, pid_, pid, 
                             prevState >>

Terminate0 == /\ pc[ParentTID] = "Terminate0"
              /\ signaledTerminate' = TRUE
              /\ pc' = [pc EXCEPT ![ParentTID] = "WakeTerm1"]
              /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                              tasks, stack, pid_, pid, prevState >>

WakeTerm1 == /\ pc[ParentTID] = "WakeTerm1"
             /\ stack' = [stack EXCEPT ![ParentTID] = << [ procedure |->  "notify",
                                                           pc        |->  "Drop",
                                                           prevState |->  prevState[ParentTID] ] >>
                                                       \o stack[ParentTID]]
             /\ prevState' = [prevState EXCEPT ![ParentTID] = defaultInitValue]
             /\ pc' = [pc EXCEPT ![ParentTID] = "DontUndoOther"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, tasks, pid_, pid >>

Drop == /\ pc[ParentTID] = "Drop"
        /\ msgToParent' = "None"
        /\ pc' = [pc EXCEPT ![ParentTID] = "Done"]
        /\ UNCHANGED << phase, ticket, signaled, condVar, signaledTerminate, 
                        tasks, stack, pid_, pid, prevState >>

StillWork == /\ pc[ParentTID] = "StillWork"
             /\ pc' = [pc EXCEPT ![ParentTID] = "ParentWork"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, tasks, stack, pid_, pid, 
                             prevState >>

parent == ParentWork \/ PMayRW0 \/ PMaySW0 \/ PMaySW1 \/ PMayRW1
             \/ OutOfWork \/ Terminate0 \/ WakeTerm1 \/ Drop \/ StillWork

ConsumerWork == /\ pc[ConsumerTID] = "ConsumerWork"
                /\ IF tasks[ConsumerTID] > 0
                      THEN /\ pc' = [pc EXCEPT ![ConsumerTID] = "FoundWork"]
                      ELSE /\ pc' = [pc EXCEPT ![ConsumerTID] = "Sleeping0"]
                /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                signaledTerminate, tasks, stack, pid_, pid, 
                                prevState >>

FoundWork == /\ pc[ConsumerTID] = "FoundWork"
             /\ tasks' = [tasks EXCEPT ![ConsumerTID] = tasks[ConsumerTID] - 1]
             /\ pc' = [pc EXCEPT ![ConsumerTID] = "isEnding"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, stack, pid_, pid, prevState >>

Sleeping0 == /\ pc[ConsumerTID] = "Sleeping0"
             /\ stack' = [stack EXCEPT ![ConsumerTID] = << [ procedure |->  "prepareParking",
                                                             pc        |->  "Sleeping1" ] >>
                                                         \o stack[ConsumerTID]]
             /\ pc' = [pc EXCEPT ![ConsumerTID] = "NotSignaled"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, tasks, pid_, pid, prevState >>

Sleeping1 == /\ pc[ConsumerTID] = "Sleeping1"
             /\ msgToParent' = "Waiting"
             /\ pc' = [pc EXCEPT ![ConsumerTID] = "Sleeping2"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, 
                             signaledTerminate, tasks, stack, pid_, pid, 
                             prevState >>

Sleeping2 == /\ pc[ConsumerTID] = "Sleeping2"
             /\ stack' = [stack EXCEPT ![ConsumerTID] = << [ procedure |->  "park",
                                                             pc        |->  "isEnding" ] >>
                                                         \o stack[ConsumerTID]]
             /\ pc' = [pc EXCEPT ![ConsumerTID] = "NotSignaled2"]
             /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                             signaledTerminate, tasks, pid_, pid, prevState >>

isEnding == /\ pc[ConsumerTID] = "isEnding"
            /\ IF signaledTerminate
                  THEN /\ pc' = [pc EXCEPT ![ConsumerTID] = "RecvTerminate"]
                  ELSE /\ pc' = [pc EXCEPT ![ConsumerTID] = "ConsumerWork"]
            /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                            signaledTerminate, tasks, stack, pid_, pid, 
                            prevState >>

RecvTerminate == /\ pc[ConsumerTID] = "RecvTerminate"
                 /\ TRUE
                 /\ pc' = [pc EXCEPT ![ConsumerTID] = "Done"]
                 /\ UNCHANGED << phase, ticket, signaled, condVar, msgToParent, 
                                 signaledTerminate, tasks, stack, pid_, pid, 
                                 prevState >>

consumer == ConsumerWork \/ FoundWork \/ Sleeping0 \/ Sleeping1
               \/ Sleeping2 \/ isEnding \/ RecvTerminate

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == parent \/ consumer
           \/ (\E self \in ProcSet:  \/ mayRequestWork(self) \/ mayShareWork(self)
                                     \/ prepareParking(self) \/ park(self)
                                     \/ notify(self))
           \/ (\E self \in producers: producer(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in producers : /\ WF_vars(producer(self))
                                   /\ WF_vars(mayRequestWork(self))
                                   /\ WF_vars(notify(self))
        /\ /\ WF_vars(parent)
           /\ WF_vars(mayRequestWork(ParentTID))
           /\ WF_vars(mayShareWork(ParentTID))
           /\ WF_vars(notify(ParentTID))
        /\ /\ WF_vars(consumer)
           /\ WF_vars(prepareParking(ConsumerTID))
           /\ WF_vars(park(ConsumerTID))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION
====
