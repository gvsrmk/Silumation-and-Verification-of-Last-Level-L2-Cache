# MSDProjectFall2019
Project - LLC

Team 16

Murali
Sumeet
Surakshit
Srinivasa




This project is implemented in System Verilog;

USE the simulation commands
vsim +FILE="filename" "mode" LLC ;

filename -> the fil containing command and operation to be performed;
mode -> can be selected as mode1 or mode2

Following are the assumption while we are simulating the LLC

·       For n=5 (Snooped Flush): This implies that the LLC which was flushing was in modified state which also implies we were in Invalidate state. Hence, we would do nothing for this case.

·       n=6 (Snooped RWIM) is always followed by an n=3 (snooped invalidate command).

·       Repeated Write/ Read requests that our LLC gets are assumed to be for a line that was earlier present in both L1 and LLC but it got evicted from L1 (maybe due to small capacity of L1(again an assumption)) and then after it getting evicted from L1, the CPU requested for it again due to which our LLC got a Read/Write request for that line. 



