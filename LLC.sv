module LLC;

// BUS OPERATION TYPES
	`define READ 			1	// Bus READ
	`define WRITE 			2	// Bus WRITE
	`define INVALIDATE 		3	// Bus INVALIDATE
	`define RWIM			4	// Bus READ with intent to modify

// SNOOP RESULT TYPES
	`define NOHIT			0	// NO Hit
	`define HIT  			1	// Hit
	`define HITM 			2	// Hit to a modified line

// L2 TO L1 MESSAGE TYPES
	`define GETLINE			1	// Request data for modified line in L1
	`define SENDLINE		2	// Send requested Cache Line to L1
	`define INVALIDATELINE	3	// Invalidate a line in L1
	`define EVICTLINE  		4	// Evict a line from L1


//======================================================= List of Parameters =======================================================	
parameter K = 2**10;									
parameter CAPACITY = 16*K*K;							// Cache capacity in MB
parameter CACHELINE = 64;								// Cache line in Bytes
parameter WAY = 8;										// Associativity of the Cache
parameter ADDRESSBITS = 32;								// Address Length
parameter TOTAL_LINES = CAPACITY / CACHELINE;			// Total number of Cache Lines
//parameter TRACEFILE = "wwcw.txt";					    // Tracefile to run 

parameter CACHELINE_BITS = $clog2(CACHELINE);			// Bits to represent a Cache Line
parameter INDEX = TOTAL_LINES / WAY;					// Number of Index (or Sets)
parameter INDEXBITS = $clog2(INDEX);					// Bits to represent the Index
parameter TAGBITS = ADDRESSBITS-(INDEXBITS+CACHELINE_BITS); // Bits to represent the Tag


//======================================================= List of internal variables =======================================================
int Readcount = 0;
real Hitcount = 0;
real Misscount = 0;
int Writecount = 0;
int Cacheaccess = 0;
real Hitratio = 0;
int SnoopedHit;
int SnoopedHitWay;
int Current_Way;
int way_to_evict;
int SnoopResult;

integer file_descriptor;
string file_string;
integer values_read;
int Result;
int n;
bit [1:0] y;
logic [ADDRESSBITS-1:0] Address;						// Address bits
logic [CACHELINE_BITS-1:0] byteoffset;					// Byte offset bits (Depends on the size of a Cache Line)
logic [INDEXBITS-1:0] index;							// Index bits (Depends on total Index present)
logic [TAGBITS-1:0] tag;								// Tag bits (The address bits excluding index bits and byteoffset)
bit [6:0] PLRUbits [INDEX]; 							// PLRU bit array for every Index

initial 
begin
//=============================== Clearing the Cache & setting all lines to INVALID prior to opening the tracefile ===============================
	ClearCache();	

if ($value$plusargs("FILE=%s", file_string))
begin
	$display("%s", file_string);
//======================================================= opening and reading the tracefile =======================================================
	file_descriptor = $fopen (file_string,"r");

//	if (file_descriptor)
//	$display("******************************************************FILE OPENED SUCCESSFULLY******************************************************");
//	else
//	$display("******************************************************!!!FILE NOT OPENED!!!******************************************************");

	while(!$feof(file_descriptor))
	begin
		values_read = $fscanf (file_descriptor, "%d %h", n, Address);

		{>>{tag, index, byteoffset}} = Address; 	// unpacking the address bits into tag, index and byteoffset by using the Streaming Operator
		//$display("\nCommand:%d Address:%h Tag:%h Index:%h Byte Offset:%h\n", n, Address, tag, index, byteoffset);

		case (n)
	
			0: begin
				Readoperation(n, Address, tag, index);
			end
			1: begin
				Writeoperation(n, Address, tag, index);
			end	
			2: begin
				Readoperation(n, Address, tag, index);
			end
			3: begin
				PutSnoopResult(n, Address, SnoopResult);
			end	
			4: begin
				PutSnoopResult(n, Address, SnoopResult);
			end	
			5: begin
				$display(" Flush observed on the Bus for Address: %h ", Address);
			end	
			6: begin
				PutSnoopResult(n, Address, SnoopResult);
			end	
			8: begin
				ClearCache();
			end
			9: begin
				PrintStats();
			end
			default: $display(" !!!Corrupted Command!!! Command:%d, Address:%h", n, Address);
		endcase 
	end
end
	if($test$plusargs("mode1"))
	begin
		$display("\n=================SUMMARY CACHE USAGE STATISTICS=================");
		$display("		NUMBER OF CACHE READS 	= %d \n", Readcount);
		$display("		NUMBER OF CACHE WRITES 	= %d \n", Writecount);
		$display("		NUMBER OF CACHE HITS 	= %d \n", Hitcount);
		$display("		NUMBER OF CACHE MISS 	= %d \n", Misscount);
		UpdateHitRatio();
		$display("		CACHE HIT RATIO 		= %f \n", Hitratio);
	end
	else if ($test$plusargs("mode2"))
		begin
		$display("\n=================SUMMARY CACHE USAGE STATISTICS=================");
		$display("		NUMBER OF CACHE READS 	= %d \n", Readcount);
		$display("		NUMBER OF CACHE WRITES 	= %d \n", Writecount);
		$display("		NUMBER OF CACHE HITS 	= %d \n", Hitcount);
		$display("		NUMBER OF CACHE MISS 	= %d \n", Misscount);
		UpdateHitRatio();
		$display("		CACHE HIT RATIO 		= %f \n", Hitratio);
	end
end 

//========================================= Declaring MESI States as a one-hot encoding  =========================================
typedef enum logic [3:0] { 	M = 4'b0001,
			  				E = 4'b0010,	
			  				S = 4'b0100,
			   				I = 4'b1000} MESI;

//======================================================= Cache Structure =======================================================
typedef struct packed { MESI MESIbits;
						bit Dirty;
						bit Valid;
						bit [TAGBITS-1:0] tagbit; } Cache;
Cache [INDEX-1:0][WAY-1:0] L2_Cache; 	// LLC Cache declared as a packed array of structs.


//======================================================= READ Task =======================================================
task Readoperation (input int n, input [ADDRESSBITS-1:0] Address, input [TAGBITS-1:0] tag, input [INDEXBITS-1:0] index);
	incrementAccesscounter();									// Incrementing the Cache Access
	incrementREADcounter();										// Increment the READ Counter
	CheckForHit(Address, tag, index, Current_Way, Result);		// Check for a Hit / Miss
	if (Result)
	begin
		//updateMESI(n, index, Current_Way); 				// Not required to update the MESI State in case of a Hit
		updatePLRU(index, Current_Way); 						// update PLRU
	end 												
	else
	begin
		incrementMISScounter();							// If Miss, Increment the Miss Counter	
		WhichWayToEvict(index, way_to_evict);			// This task will return the way to evict ie. least used way 
		L2_Cache [index][way_to_evict].tagbit = tag; 	// Fetch data from DRAM (basically update the least used way with our current tag bits)
		updateMESI(n, index, way_to_evict); 			// This task will do a Bus Operation (Bus Read) & Gather snoop result (in terms of HIT, HITM or NOHIT) 
														// Also, Update the MESI STate of that line & set valid bit to 1
		updatePLRU(index, way_to_evict);				// Make this way as most Recently Used way
	end
endtask : Readoperation


//======================================================= WRITE Task =======================================================
task Writeoperation (input int n, input [ADDRESSBITS-1:0] Address, input [TAGBITS-1:0] tag, input [INDEXBITS-1:0] index);
	incrementAccesscounter();								// Incrementing the Cache Access
	incrementWRITEcounter();								// Increment the Write Counter
	CheckForHit(Address, tag, index, Current_Way, Result);	// Check for a Hit / Miss
	if (Result)
	begin
		updateMESI(n, index, Current_Way); 					// change MESI State of that line (if Modified it would stay the same)
															// incase of Shared or Exclusive, it would change to modified
		updatePLRU(index, Current_Way);						// update PLRU 	
	end 																		
	else
	begin
		incrementMISScounter();								// If Miss, increment the Miss Counter
		WhichWayToEvict(index, way_to_evict);				// This task will return the way to evict ie. least used way
		L2_Cache [index][way_to_evict].tagbit = tag; 		// Fetch data from DRAM (basically update the least used way with our current tag bits)

		updateMESI(n, index, way_to_evict);	   				// This task will do a Bus operation (Read with an intent to modify)
															// Do another Bus operation (Tell others to invalidate their copy)
															// Gather snoop result (in terms of HIT, HITM or NOHIT)
															// change MESI State of that line
															// set valid to 1, dirty bit to 1
		
		updatePLRU(index, way_to_evict);					// Make this way as most Recently Used way
	end
endtask : Writeoperation


//================================== Task to perform a Bus Operation and gather snoop results provided by LLCs of other processors ==================================
task automatic Busoperation (input int BusOp, input [ADDRESSBITS-1:0] Address, output int SnoopResult);
	GetSnoopResult(Address, SnoopResult);
	if ($test$plusargs("mode2"))
	begin
		$display("\n=================BUS OPERATION PERFORMED TO GATHER DATA FROM DRAM=================\n");
		$display("\n BusOperation:%d Address:%h Obtained Snoop Result:%d\n", BusOp, Address, SnoopResult);
	end
endtask : Busoperation


//======================= Task to simulate the reporting of snoop results provided by LLCs of other processors caches when we do a Bus Operation =======================
task automatic GetSnoopResult(input [ADDRESSBITS-1:0] Address, output int SnoopResult);		
	case(y)
		2'b00: SnoopResult = `HIT;
		2'b01: SnoopResult = `HITM;
		2'b10: SnoopResult = `NOHIT;
		2'b11: SnoopResult = `NOHIT;
	endcase 
endtask


//======================================== Task to provide our snoop results to the processor's LLC which performed a Bus Operation ========================================
task automatic PutSnoopResult (input int n, input [ADDRESSBITS-1:0] Address, output int SnoopResult);
	CheckForSnoopedHit(tag, index, SnoopedHitWay, SnoopedHit);
	if (SnoopedHit)
	begin
		if (L2_Cache [index][SnoopedHitWay].MESIbits == M)
		begin
			SnoopResult = `HITM;
			updateMESI(n, index, SnoopedHitWay);
		end
		else 
		begin
			SnoopResult = `HIT;
			updateMESI(n, index, SnoopedHitWay);
		end
	end
	else
		begin
			SnoopResult = `NOHIT;
		end

	if ($test$plusargs("mode2"))
		begin
		$display("\n=================PROVIDING OUR SNOOP RESULTS=================\n");
		$display("\n Address:%h Asserted SnoopResult:%d\n", Address,SnoopResult);
end
endtask : PutSnoopResult


//====================================================================== Task to Update the PLRU bits ======================================================================
task automatic updatePLRU( input [INDEXBITS-1:0] index, input int Way);
	case(Way)
    
    0:  begin
          PLRUbits[index][0] = 0;
          PLRUbits[index][1] = 0;
          PLRUbits[index][3] = 0;
        end
    1:  begin
          PLRUbits[index][0] = 0;
          PLRUbits[index][1] = 0;
          PLRUbits[index][3] = 1;
        end  
    2:  begin
          PLRUbits[index][0] = 0;
          PLRUbits[index][1] = 1;
          PLRUbits[index][4] = 0;
        end          
    3:  begin
          PLRUbits[index][0] = 0;
          PLRUbits[index][1] = 1;
          PLRUbits[index][4] = 1;
        end
    4:  begin
          PLRUbits[index][0] = 1;
          PLRUbits[index][2] = 0;
          PLRUbits[index][5] = 0;
        end  
    5:  begin
          PLRUbits[index][0] = 1;
          PLRUbits[index][2] = 0;
          PLRUbits[index][5] = 1;
        end   
    6:  begin
          PLRUbits[index][0] = 1;
          PLRUbits[index][2] = 1;
          PLRUbits[index][6] = 0;
        end
    7:  begin
          PLRUbits[index][0] = 1;
          PLRUbits[index][2] = 1;
          PLRUbits[index][6] = 1;
        end  
  	endcase
endtask : updatePLRU


// ================================================================ Task to choose which way to evict based on the PLRU Bits ================================================================
task automatic WhichWayToEvict(input [INDEXBITS-1:0] index, output int way_to_evict);  
if(PLRUbits[index][0]==0)
 	begin
 		if(PLRUbits[index][2]==0)
 		begin
 			if(PLRUbits[index][6]==0)
 			way_to_evict=7;
 			else if(PLRUbits[index][6]==1) 
 			way_to_evict=6; 
 		end

 		else if (PLRUbits[index][2]==1)
 		begin
 			if (PLRUbits[index][5]==0) 		
 			way_to_evict=5;
 			else if(PLRUbits[index][5]==1) 	
 			way_to_evict=4;
 		end
 	end
 		else if(PLRUbits[index][0]==1)
 		begin
 			if(PLRUbits[index][1]==0)
 			begin
 				if(PLRUbits[index][4]==0) 	
 				way_to_evict=3;
 				else if(PLRUbits[index][4]==1) 	
 				way_to_evict=2;
 			end
 		
 		else if (PLRUbits[index][1]==1)
 		begin
 				if (PLRUbits[index][3]==0) 		
 				way_to_evict=1;
 				else if(PLRUbits[index][3]==1) 	
 				way_to_evict=0;
 		end
 	end
endtask : WhichWayToEvict


// ================================================================ Task to Update the MESI State ================================================================
task automatic updateMESI (input int n, input [INDEXBITS-1:0] index, input int Way_to_Update);
	if (n == 0 || n == 2)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				L2_Cache[index][Way_to_Update].MESIbits = M;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b1;
			end
			E: begin 
				L2_Cache[index][Way_to_Update].MESIbits = E;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			S: begin
				L2_Cache[index][Way_to_Update].MESIbits = S;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			I: begin
				Busoperation(`READ, Address, SnoopResult);
				if(SnoopResult == `HIT || SnoopResult == `HITM) 
				begin 
					L2_Cache[index][Way_to_Update].MESIbits = S;
					L2_Cache[index][Way_to_Update].Valid = 1'b1;
					L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				end
				else if(SnoopResult == `NOHIT) 
				begin
					L2_Cache[index][Way_to_Update].MESIbits = E;
					L2_Cache[index][Way_to_Update].Valid = 1'b1;
					L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				end
			end
		endcase
	end
	else if (n == 1)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				L2_Cache[index][Way_to_Update].MESIbits = M;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b1;
			end
			E: begin
				L2_Cache[index][Way_to_Update].MESIbits = M;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b1;
			end
			S: begin
				Busoperation(`INVALIDATE, Address, SnoopResult);
				L2_Cache[index][Way_to_Update].MESIbits = M;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b1;
				end
			I: begin
				Busoperation(`RWIM, Address, SnoopResult);
				if (SnoopResult == `HIT || SnoopResult == `HITM)
				begin
					Busoperation(`INVALIDATE, Address, SnoopResult);
					L2_Cache[index][Way_to_Update].MESIbits = M;
					L2_Cache[index][Way_to_Update].Valid = 1'b1;
					L2_Cache[index][Way_to_Update].Dirty = 1'b1;
				end
				else
				begin
					L2_Cache[index][Way_to_Update].MESIbits = M;
					L2_Cache[index][Way_to_Update].Valid = 1'b1;
					L2_Cache[index][Way_to_Update].Dirty = 1'b1;
				end
			end
		endcase
	end
	else if (n == 3)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				MessageToCache(`INVALIDATE, Address);
			end
			E: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				MessageToCache(`INVALIDATE, Address);
			end
			S: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				MessageToCache(`INVALIDATE, Address);
			end
			I: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
		endcase
	end
	else if (n == 4)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				MessageToCache(`GETLINE, Address);
				Busoperation(`WRITE, Address, SnoopResult);
				L2_Cache[index][Way_to_Update].MESIbits = S;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			E: begin
				L2_Cache[index][Way_to_Update].MESIbits = S;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			S: begin
				L2_Cache[index][Way_to_Update].MESIbits = S;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			I: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
		endcase
	end
	else if (n == 5)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				L2_Cache[index][Way_to_Update].MESIbits = M;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b1;
			end
			E: begin
				L2_Cache[index][Way_to_Update].MESIbits = E;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			S: begin
				L2_Cache[index][Way_to_Update].MESIbits = S;
				L2_Cache[index][Way_to_Update].Valid = 1'b1;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end	
			I: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
		endcase
	end
	else if (n == 6)
	begin
		case (L2_Cache[index][Way_to_Update].MESIbits)
			M: begin
				MessageToCache(`EVICTLINE, Address);
				Busoperation(`WRITE, Address, SnoopResult); 
			    L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
			E: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				MessageToCache(`INVALIDATE, Address);
			end
			S: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
				MessageToCache(`INVALIDATE, Address);
			end
			I: begin
				L2_Cache[index][Way_to_Update].MESIbits = I;
				L2_Cache[index][Way_to_Update].Valid = 1'b0;
				L2_Cache[index][Way_to_Update].Dirty = 1'b0;
			end
		endcase
	end
	
endtask : updateMESI


// ================================================================ Task to simulate communication to our higher level Cache ================================================================
task automatic MessageToCache (input int Message, input [ADDRESSBITS-1:0] Address);
	if ($test$plusargs("mode2"))
	begin
		if (Message == `EVICTLINE)
		begin
		$display("\n=================COMMUNICATING WITH L1=================\n");			
		$display("L2: %d %h\n `GETLINE to obtain the line at %h from L1 \n `INVALIDATE to invalidate the line at %h \n %d operation complete!\n", Message, Address, Address, Address, Message);
		end
		else
		begin
			$display("\n=================COMMUNICATING WITH L1=================\n");			
			$display("Message:%d Address:%h\n", Message, Address);
		end
	end
endtask : MessageToCache


// ================================================================ Task to Check for a Snooped Hit ================================================================
task automatic CheckForSnoopedHit (input[TAGBITS-1:0] tag, input [INDEXBITS-1:0] index, output int SnoopedHitWay, output int SnoopedHit);
	SnoopedHit = 0;
	for (int i = 0; i < WAY; i++)
	begin
		if ((L2_Cache[index][i].Valid == 1) && (L2_Cache [index][i].tagbit == tag))	
		begin
		SnoopedHitWay=i;
		SnoopedHit = 1;
		end
	end
endtask: CheckForSnoopedHit


//=================================================== Task to Check for a HIT ===================================================
task automatic CheckForHit(input [ADDRESSBITS-1:0]  Address, input [TAGBITS-1:0] tag, input [INDEXBITS-1:0]  index, output int Current_Way, output int Result);
Result = 0;
for (int i = 0; i < WAY; i++)
begin
	if ((L2_Cache[index][i].Valid == 1) && (L2_Cache [index][i].tagbit == tag))
	begin	
	incrementHITcounter();						// Hit counter is incremented on every Hit
	MessageToCache(`SENDLINE, Address);			// On every Hit, the requested line is sent to L1
	Result = 1;
	Current_Way = i;
	end
end
endtask : CheckForHit


//========================================= Task to Clear the cache and Reset all states =========================================
task ClearCache();
for (int i=0; i<INDEX; i++)
	begin					
		for (int j=0; j<WAY; j++)			// Do Evictline before Clearing a Modified line
		begin
			if (L2_Cache [i][j].MESIbits == M)
			MessageToCache(`EVICTLINE, L2_Cache [i][j].tagbit);	
		end
	end

	for (int i=0; i<INDEX; i++)
	begin					
		for (int j=0; j<WAY; j++)			// Clear Cache and Reset MESI State (Setting MESI State to Invalid)
		begin
		//	L2_Cache [i][j].tagbit = '0;
			L2_Cache [i][j].MESIbits = I;
			L2_Cache [i][j].Valid = 0;
			L2_Cache [i][j].Dirty = 0;
		end
	end

	for (int i = 0; i < INDEX; i++) 		// Reset the PLRU bits
	begin					
		for (int j=0; j<WAY-1; j++)			
		begin
		PLRUbits [i][j]= 1'b0;					
		end
	end
endtask : ClearCache


//=================================== Task to Print contents and State of each valid cache line  ===================================
task PrintStats();
$display("=================================== Displaying contents and State of each valid cache line of LLC  ===================================",);
for (int i=0; i<INDEX; i++)
	begin
		//$display("\nINDEX:%h PLRU Bits:%p\n", i, PLRUbits[i][6:0]);
		for (int j=0; j<WAY; j++)
		begin
			if (L2_Cache [i][j].MESIbits !== I)
			$display("INDEX:%h WAY:%d VALID:%d DIRTY:%d TAG:%h MESI STATE:%s \n", i, j, L2_Cache [i][j].Valid, L2_Cache [i][j].Dirty, L2_Cache [i][j].tagbit, L2_Cache [i][j].MESIbits);
		end	
	end
endtask : PrintStats


//================================================= Task to Compute Cache Hit Ratio  =================================================
task UpdateHitRatio();
		Hitratio = (Hitcount) / (Hitcount+Misscount);
endtask : UpdateHitRatio


//========================================= Tasks to increment CACHE access, READ, WRITE, HIT and MISS Counts =====================================
task incrementAccesscounter();
	Cacheaccess = Cacheaccess+1;
endtask : incrementAccesscounter

task incrementREADcounter();
	Readcount = Readcount+1;
endtask : incrementREADcounter

task incrementWRITEcounter();
	Writecount = Writecount+1;
endtask : incrementWRITEcounter

task incrementHITcounter();
	Hitcount = Hitcount+1;
endtask : incrementHITcounter

task incrementMISScounter();
	Misscount = Misscount+1;
endtask : incrementMISScounter

endmodule : LLC
