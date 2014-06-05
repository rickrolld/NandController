//Potential timing problems:
// DQS and clk90 are not aligned on a read. It appears that ISERDESE2 align its output to 
// OCLK (which is clk90), but I cannot be sure. 
//At power up, default mode is * asynchronous mode 0 *


import Connectable       ::*;
import Clocks            ::*;
import FIFO              ::*;
import FIFOF             ::*;
import SpecialFIFOs      ::*;
import TriState          ::*;
import Vector            ::*;
import Counter           ::*;
import DefaultValue      ::*;


import NandPhyWrapper::*;
import NandInfra::*;

interface PhyUser;
	method Action sendCmd (PhyCmd cmd);
	method Action sendAddr (Bit#(8) addr);
	method Action asyncWrByte (Bit#(8) data);
	method ActionValue#(Bit#(16)) syncRdWord();
	method ActionValue#(Bit#(8)) asyncRdByte();
	method Action syncWrWord (Bit#(16) data);
	method Action setDebug (Bit#(8) d);
	method Action setDebug90 (Bit#(8) d);
endinterface

interface NandPhyIfc;
	(* prefix = "" *)
	interface NANDPins nandPins;
	interface PhyUser phyUser;
endinterface


typedef enum {
	INIT_WAIT				= 0,
	ADJ_IDELAY_DQ			= 1,
	ADJ_IDELAY_DQS			= 2,
	INIT_NAND_PWR_WAIT	= 3,
	INIT_WP					= 4,
	WAIT_CYCLES				= 5,
	IDLE						= 6,
	ASYNC_CHIP_SEL			= 7,
	ASYNC_CMD_SET_CMD		= 8,
	ASYNC_CMD_LATCH_WE	= 9,
	ASYNC_READ_RE_LOW		= 10,
	ASYNC_READ_CAPTURE	= 11,
	ASYNC_READ_RE_HIGH	= 12,
	ASYNC_ADDR_WE_LOW		= 13,
	ASYNC_ADDR_WE_HIGH	= 14,
	ASYNC_WRITE_WE_LOW	= 15,
	ASYNC_WRITE_WE_HIGH	= 16,
	ASYNC_DONE				= 17,


	SYNC_CMD_SET			= 20,
	SYNC_CMD_LATCH			= 21,
	SYNC_READ_WR_LOW 		= 22,
	SYNC_READ_LATCH		= 23,
	SYNC_READ_CAPTURE		= 24,
	SYNC_ADDR_SET			= 25,
	SYNC_ADDR_LATCH		= 26,
	SYNC_ADDR_BURST		= 27,
	SYNC_WRITE_PREAMBLE	= 28,
	SYNC_WRITE_BURST		= 29,
	SYNC_CALIB_WR_LOW		= 30,
	SYNC_CALIB_LATCH		= 31,
	SYNC_CALIB_DEQ			= 32,
	SYNC_CALIB_CALIBRATE	= 33,
	SYNC_CALIB_FAIL		= 34,

	SYNC_CHIP_SEL			= 40,
	SYNC_DONE				= 41,
	
	DESELECT_ALL			= 50,
	ENABLE_NAND_CLK		= 51


} PhyState deriving (Bits, Eq);

typedef enum {
	PHY_ASYNC_CHIP_SEL,
	PHY_ASYNC_CMD,
	PHY_ASYNC_READ,
	PHY_ASYNC_WRITE,
	PHY_ASYNC_ADDR,
	PHY_SYNC_CALIB,
	PHY_SYNC_CHIP_SEL,
	PHY_SYNC_CMD,
	PHY_SYNC_READ,
	PHY_SYNC_WRITE,
	PHY_SYNC_ADDR,
	PHY_DESELECT_ALL,
	PHY_ENABLE_NAND_CLK
} PhyCycle deriving (Bits, Eq);

typedef enum {
	N_RESET = 8'hFF,
	N_READ_STATUS = 8'h70,
	N_SET_FEATURES = 8'hEF,
	N_PROGRAM_PAGE = 8'h80,
	N_PROGRAM_PAGE_END = 8'h10,
	N_READ_MODE = 8'h00,
	N_READ_PAGE_END = 8'h30,
	N_ERASE_BLOCK = 8'h60,
	N_ERASE_BLOCK_END = 8'hD0,
	N_READ_ID = 8'h90

} ONFICmd deriving (Bits, Eq);

//using tagged union
typedef union tagged {
	ONFICmd OnfiCmd;
	Bit#(4) ChipSel;
} NandCmd deriving (Bits);

typedef struct {
	PhyCycle phyCycle;
	NandCmd nandCmd;
	Bit#(16) numBurst;
	Bit#(32) postCmdWait; //number of cycles to wait after the command
} PhyCmd deriving (Bits);


//Default clock and resets are: clk0 and rst0
(* synthesize *)
module mkNandPhy#(
	Clock clk90, 
	Reset rst90
	)(NandPhyIfc);

	//Conservative timing parameters. In clock cycles. a
	Integer t_SYS_RESET = 1000; //System reset wait
	//TODO FIXME: power up reduced using SHORT_RESET
	Integer t_POWER_UP = 100; //100us. TODO: Reduced to 1us for sim. 
	Integer t_WW = 20; //100ns. Write protect wait time.
	Integer t_ASYNC_CMD_SETUP = 8; //Max async cmd/data setup time before WE# latch
	Integer t_ASYNC_CMD_HOLD = 5; //Max async cmd/data hold time after WE# latch
	Integer t_ASYNC_ADDR_SETUP = 8; //Max async addr setup time before WE# latch
	Integer t_ASYNC_ADDR_HOLD = 5; //Max async addr hold time after WE# latch
	Integer t_ASYNC_WRITE_SETUP = 8; //Max async wr data setup time before WE# latch
	Integer t_ASYNC_WRITE_HOLD = 5; //Max async wr data hold time after WE# latch
	Integer t_RP = 7; //50ns. Async RE# pulse width. Mode 0.
	Integer t_REH = 5; //30ns. Async RE# High hold time. Note: tRC=tRP+tREH >100n
	//Sync timing params
	Integer t_CAD = 3; //25ns 
	Integer t_CMD_DQ_SYNCREG_DELAY = 2; //2 sync regs used for DQ cmd path
	Integer t_WRCK_DQSD = 4; //20ns. Chose a safe value to wait until NAND drives DQS
	Integer t_DQSCK = 2; //TODO: probably needs tweaking
	Integer t_ISERDES = 4; //cycs for data to appear from DQ to output of ISERDESE2 TODO: tweak
	Integer t_CKWR = 3; 
	Integer t_CKWR_DQSCK_ISERDES = 2; //( tCKWR - (t_DQSCK+t_ISERDES) ) Num of cycs to wait after read bursting
	Integer t_WPRE = 2; //15ns
	Integer t_WPST = 2; //15ns
	Integer t_DQSS = 2; //7.5 to 12.5ns

	//IDelay Tap value (0 to 31)
	Integer idelayDQS = 10;
	Integer idelayDQ = 0;

	//number of calibration bursts to sample
	Integer calibFifoDepth = 16;

	Clock defaultClk0 <- exposeCurrentClock();
	Reset defaultRst0 <- exposeCurrentReset();

	VNANDPhy vnandPhy <- vMkNandPhy(defaultClk0, clk90, defaultRst0, rst90);

	//State registers
	Reg#(PhyState) currState <- mkReg(INIT_WAIT);
	Reg#(PhyState) returnState <- mkReg(INIT_WAIT);
	//Reg#(PhyState) currState90 <- mkSyncRegFromCC(INIT_WAIT, clk90);

	//Timing wait counters
	Reg#(Bit#(32)) waitCnt <- mkReg(0);

	//Registers for command inputs
	Reg#(Bit#(8)) cen <- mkReg(8'hFF);
	Reg#(Bit#(1)) cle <- mkReg(0);
	Reg#(Bit#(1)) ale <- mkReg(0);
	Reg#(Bit#(1)) wrn <- mkReg(1);
	Reg#(Bit#(1)) wen <- mkReg(1); //WE# = NAND_CLK when wenSel=0
	Reg#(Bit#(1)) wenSel <- mkReg(1); //WE# by default. until sync mode active
	Reg#(Bit#(1)) wpn <- mkReg(0);
	//Reg#(Bit#(1)) cmdSelDQ <- mkReg(1);

	//Registers for write data DQ
	Reg#(Bit#(8)) wrDataRise <- mkReg(0); 
	Reg#(Bit#(8)) wrDataFall <- mkReg(0); 
	Reg#(Bit#(1)) oenDataDQ <- mkReg(1); 
	Reg#(Bit#(1)) iddrRstDQ <- mkReg(1); //assert reset until we need IDDR

	//Registers for DQS
	Reg#(Bit#(1)) oenDQS <- mkReg(1); 
	Reg#(Bit#(1)) rstnDQS <- mkReg(0);//set to 1 to enable DQS toggle

	//Delay adjustment registers
	//Reg#(Bit#(5)) incIdelayDQS_90 <- mkReg(0, clocked_by clk90, reset_by rst90);
	//Reg#(Bit#(1)) dlyIncDQSr <- mkReg(0, clocked_by clk90, reset_by rst90);
	//Reg#(Bit#(1)) dlyCeDQSr <- mkReg(0, clocked_by clk90, reset_by rst90);
	//Reg#(Bool) initDoneSync <- mkSyncRegToCC(False, clk90, rst90);

	//Calibration registers, FIFOs and Counters
	Reg#(Bit#(8)) rLat <- mkReg(fromInteger(calibFifoDepth)); //initialize to max rLat
	Reg#(Bit#(1)) calibClk0Sel <- mkReg(0);
	Reg#(Bit#(8)) refDqR <- mkReg(8'h2C); //TODO how to set this
	FIFO#(Bit#(8)) fifoDqR0 <- mkSizedFIFO(calibFifoDepth);
	FIFO#(Bit#(8)) fifoDqR90 <- mkSizedFIFO(calibFifoDepth);
	FIFO#(Bit#(8)) fifoDqR180 <- mkSizedFIFO(calibFifoDepth);
	FIFO#(Bit#(8)) fifoDqR270 <- mkSizedFIFO(calibFifoDepth);
	Reg#(Bit#(16)) numCalibBrCnt <- mkReg(0);

	//Debug registers
	//Reg#(Bit#(8)) debugR90 <- mkReg(0, clocked_by clk90, reset_by rst90);
	Reg#(Bit#(8)) debugR <- mkReg(0);
	Reg#(Bit#(8)) debugR90 <- mkReg(0); //TODO not actually clk90

	//Command and address FIFO
	FIFO#(PhyCmd) ctrlCmdQ <- mkFIFO();
	FIFO#(Bit#(8)) addrQ <- mkSizedFIFO(32);

	//Counters
	Reg#(Bit#(16)) numBurstCnt <- mkReg(0);
	Reg#(Bit#(32)) postCmdWaitCnt <- mkReg(0);
	Reg#(Bit#(8)) cntRdDelay <- mkReg(0);
	Reg#(Bit#(16)) numBurstCntBr <- mkReg(0);

	//Read/write data FIFO
	FIFO#(Bit#(8)) asyncRdQ <- mkSizedFIFO(32); //TODO adjust size
	FIFO#(Bit#(8)) asyncWrQ <- mkSizedFIFO(32); //TODO adjust size
	FIFO#(Bit#(16)) syncRdQ <- mkSizedFIFO(32); //TODO adjust size
	FIFO#(Bit#(16)) syncWrQ <- mkSizedFIFO(32); //TODO adjust size

	//**********************************************
	// Buffer phy signals using registers in front
	//**********************************************
	/*
	rule regBufs90;
		vnandPhy.vphyUser.dlyCeDQS(dlyCeDQSr);
		vnandPhy.vphyUser.dlyIncDQS(dlyIncDQSr);
	endrule
	*/

	rule regBufs;
		vnandPhy.vphyUser.setCLE(cle);
		vnandPhy.vphyUser.setALE(ale);
		vnandPhy.vphyUser.setWRN(wrn);
		vnandPhy.vphyUser.setWPN(wpn);
		vnandPhy.vphyUser.setCEN(cen);
		vnandPhy.vphyUser.setWEN(wen);
		vnandPhy.vphyUser.setWENSel(wenSel);
		vnandPhy.vphyUser.oenDQS(oenDQS);
		vnandPhy.vphyUser.rstnDQS(rstnDQS);
		vnandPhy.vphyUser.oenDataDQ(oenDataDQ);
		vnandPhy.vphyUser.iddrRstDQ(iddrRstDQ);
		vnandPhy.vphyUser.wrDataRiseDQ(wrDataRise);
		vnandPhy.vphyUser.wrDataFallDQ(wrDataFall);
		vnandPhy.vphyUser.setCalibClk0Sel(calibClk0Sel);
		vnandPhy.vphyUser.setDebug(debugR);
		vnandPhy.vphyUser.setDebug90(debugR90);
	endrule

	//wait rule. 
	rule doWaitCycles if (currState==WAIT_CYCLES);
		//By entering and exiting this state, we're already waiting 2 cycles. 
		if (waitCnt>2) begin
			waitCnt <= waitCnt-1;
		end
		else begin
			currState <= returnState;
		end
	endrule
		
	//**********************************************
	// Initialize IDELAY and NAND chip
	//**********************************************

	rule doInitWait if (currState==INIT_WAIT);
		wpn <= 0;
		waitCnt <= fromInteger(t_SYS_RESET);
		currState <= WAIT_CYCLES;
		returnState <= INIT_NAND_PWR_WAIT;
		$display("@%t\t NandPhy: INIT_WAIT", $time);
	endrule

	/*
	rule doWaitIdelayDQS if (currState==ADJ_IDELAY_DQS);
		if (initDoneSync==True) begin
			currState <= INIT_NAND_PWR_WAIT;
		end
	endrule
	*/

	//power up initialization by the NAND
	rule doInitNandPwrWait if (currState==INIT_NAND_PWR_WAIT);
		waitCnt <= fromInteger(t_POWER_UP);
		currState <= WAIT_CYCLES;
		returnState <= INIT_WP; 
		$display("@%t\t NandPhy: INIT_NAND_PWR_WAIT", $time);
	endrule

	//Turn off Write Protect. Wait tWW (>100ns). WP is always active, thus don't need CE. 
	rule doWP if (currState==INIT_WP);
		wpn <= 1;
		waitCnt <= fromInteger(t_WW);
		currState <= WAIT_CYCLES;
		returnState <= IDLE; 
		$display("@%t\t NandPhy: INIT_WP", $time);
	endrule

	//****************************************
	// Idle and accepting new commands
	//****************************************

	rule doIdle if (currState==IDLE);
		let cmd = ctrlCmdQ.first();
		case(cmd.phyCycle)
			PHY_ASYNC_CHIP_SEL: currState <= ASYNC_CHIP_SEL;
			PHY_ASYNC_CMD: currState <= ASYNC_CMD_SET_CMD;
			PHY_ASYNC_READ: currState <= ASYNC_READ_RE_LOW;
			PHY_ASYNC_ADDR: currState <= ASYNC_ADDR_WE_LOW;
			PHY_ASYNC_WRITE: currState <= ASYNC_WRITE_WE_LOW;
			PHY_DESELECT_ALL: currState <= DESELECT_ALL;
			PHY_ENABLE_NAND_CLK: currState <= ENABLE_NAND_CLK;
			PHY_SYNC_CALIB: currState <= SYNC_CALIB_WR_LOW;
			PHY_SYNC_CMD: currState <= SYNC_CMD_SET;
			PHY_SYNC_READ: currState <= SYNC_READ_WR_LOW;
			PHY_SYNC_ADDR: currState <= SYNC_ADDR_SET;
			PHY_SYNC_WRITE: currState <= SYNC_WRITE_PREAMBLE;
			PHY_SYNC_CHIP_SEL: currState <= SYNC_CHIP_SEL;
			default: currState <= IDLE;
		endcase
		numBurstCnt <= cmd.numBurst;
		numBurstCntBr <= cmd.numBurst;
		postCmdWaitCnt <= cmd.postCmdWait;
		$display("@%t\t NandPhy: New command received: %x", $time, cmd.phyCycle);
	endrule

	//****************************************
	// Async bus idle/chip select
	//****************************************
	rule doAsyncCmdBusIdle if (currState==ASYNC_CHIP_SEL);
		//one hot encode CE#
		Bit#(4) ce_encoded = ctrlCmdQ.first().nandCmd.ChipSel;
		Bit#(8) cen_one_hot = ~(1 << ce_encoded);
		cen <= cen_one_hot; //CE# low
		cle <= 0; //DC
		ale <= 0; //DC
		wrn <= 1; //RE# high
		wen <= 1;//select and set WE# high (NAND_CLK)
		wenSel <= 1; 
		oenDataDQ <= 1; //disable output
		currState <= IDLE;
		ctrlCmdQ.deq();
		$display("@%t\t NandPhy: ASYNC_CHIP_SEL %x", $time, cen_one_hot);
	endrule

	//****************************************
	// Async command
	//****************************************
	rule doAsyncCmdSetup if (currState==ASYNC_CMD_SET_CMD);
		cle <= 1;
		wen <= 0; 
		oenDataDQ <= 0; //enable cmd output on DQ
		wrDataRise <= pack(ctrlCmdQ.first().nandCmd.OnfiCmd); //set command
		wrDataFall <= pack(ctrlCmdQ.first().nandCmd.OnfiCmd); //set command
		//Wait for setup
		waitCnt <= fromInteger(t_ASYNC_CMD_SETUP);
		currState <= WAIT_CYCLES;
		returnState <= ASYNC_CMD_LATCH_WE;
		$display("@%t\t NandPhy: ASYNC_CMD_SET_CMD: %x", $time, ctrlCmdQ.first().nandCmd.OnfiCmd);
	endrule

	rule doAsyncCmdLatch if (currState==ASYNC_CMD_LATCH_WE);
		wen <= 1;
		waitCnt <= fromInteger(t_ASYNC_CMD_HOLD);
		currState <= WAIT_CYCLES;
		returnState <= ASYNC_DONE;
		$display("@%t\t NandPhy: ASYNC_CMD_LATCH_WE", $time);
	endrule

	//****************************************
	// Async address cycle; assume bus idle
	//****************************************
	rule doAsyncAddrWeLow if (currState==ASYNC_ADDR_WE_LOW);
		ale <= 1; //High
		wen <= 0;//select and set WE# low
		oenDataDQ <= 0; //enable output. Note this signal needs 2 cycles to propogate
		wrDataRise <= addrQ.first(); //set address output
		wrDataFall <= addrQ.first(); //set address output
		addrQ.deq();
		//wait for setup
		waitCnt <= fromInteger(t_ASYNC_ADDR_SETUP);
		currState <= WAIT_CYCLES;
		returnState <= ASYNC_ADDR_WE_HIGH;
		$display("@%t\t NandPhy: ASYNC_ADDR_WE_LOW set addr: %x", $time, addrQ.first);
	endrule

	rule doAsyncAddrWeHigh if (currState==ASYNC_ADDR_WE_HIGH);
		wen <= 1; //set WE# high to latch addr
		//wait for hold
		waitCnt <= fromInteger(t_ASYNC_ADDR_HOLD);
		currState <= WAIT_CYCLES;
		if (numBurstCnt==1) begin
			returnState <= ASYNC_DONE;
		end
		else begin
			returnState <= ASYNC_ADDR_WE_LOW;
			numBurstCnt <= numBurstCnt - 1;
		end
		$display("@%t\t NandPhy: ASYNC_ADDR_WE_HIGH", $time);
	endrule



	//*************************************************************
	// Async data input cycle (write to NAND); assume bus idle
	//*************************************************************
	rule doAsyncWriteWeLow if (currState==ASYNC_WRITE_WE_LOW);
		wen <= 0;//select and set WE# low
		oenDataDQ <= 0; //enable output. Note this signal needs 2 cycles to propogate
		wrDataRise <= asyncWrQ.first(); //set data output
		wrDataFall <= asyncWrQ.first(); //set data output
		asyncWrQ.deq();
		//wait for setup
		waitCnt <= fromInteger(t_ASYNC_WRITE_SETUP);
		currState <= WAIT_CYCLES;
		returnState <= ASYNC_WRITE_WE_HIGH;
		$display("@%t\t NandPhy: ASYNC_WRITE_WE_LOW set data: %x", $time, asyncWrQ.first);
	endrule

	rule doAsyncWriteWeHigh if (currState==ASYNC_WRITE_WE_HIGH);
		wen <= 1; //set WE# high to latch write data
		//wait for hold
		waitCnt <= fromInteger(t_ASYNC_WRITE_HOLD);
		currState <= WAIT_CYCLES;
		if (numBurstCnt==1) begin
			returnState <= ASYNC_DONE;
		end
		else if (numBurstCnt>0) begin
			returnState <= ASYNC_WRITE_WE_LOW;
			numBurstCnt <= numBurstCnt - 1;
		end
		else begin
			$display("NandPhy: ERROR: num bursts is incorrect. Must be >1");
		end
		$display("@%t\t NandPhy: ASYNC_WRITE_WE_HIGH", $time);
	endrule


	//*************************************************************
	// Async data output cycle (read from NAND); Assume bus idle
	//*************************************************************
	rule doAsyncReadReLow if (currState==ASYNC_READ_RE_LOW);
		oenDataDQ <= 1; //disable output. 
		//toggle RE# to capture data
		wrn <= 0;
		//wait tRP
		waitCnt <= fromInteger(t_RP);
		currState <= WAIT_CYCLES;
		returnState <= ASYNC_READ_CAPTURE;
		$display("@%t\t NandPhy: ASYNC_READ_RE_LOW", $time);
	endrule

	rule doAsyncReadCapture if (currState==ASYNC_READ_CAPTURE);
		//get data
		let rddata = vnandPhy.vphyUser.rdDataCombDQ();
		asyncRdQ.enq(rddata);
		$display("@%t\t NandPhy: ASYNC_READ_CAPTURE async read data %x", $time, rddata);
		currState <= ASYNC_READ_RE_HIGH;
	endrule
	

	rule doAsyncReadReHigh if (currState==ASYNC_READ_RE_HIGH);
		wrn <= 1;
		//wait tREH
		waitCnt <= fromInteger(t_REH);
		currState <= WAIT_CYCLES;
		//if done bursting, go idle. otherwise keep toggling RE#
		if (numBurstCnt==1) begin
			returnState <= ASYNC_DONE;
		end
		else if (numBurstCnt > 1) begin
			returnState <= ASYNC_READ_RE_LOW;
			numBurstCnt <= numBurstCnt - 1;
		end
		else begin
			$display("NandPhy: ERROR: num bursts is incorrect. Must be >1");
		end
		$display("@%t\t NandPhy: ASYNC_READ_RE_HIGH", $time);
	endrule


	//**************************
	// Go bus idle if done (ASYNC)
	//**************************
	rule doAsyncDone if (currState==ASYNC_DONE);
		cle <= 0; //DC
		ale <= 0; //DC
		wrn <= 1; //RE# high
		wen <= 1;//select and set WE# high (NAND_CLK)
		wenSel <= 1; 
		oenDataDQ <= 1; //disable output

		//post command wait
		if (postCmdWaitCnt > 0) begin
			currState <= WAIT_CYCLES;
			waitCnt <= postCmdWaitCnt;
			returnState <= IDLE;
		end
		else begin
			currState <= IDLE;
		end
		ctrlCmdQ.deq();
		$display("@%t\t NandPhy: ASYNC_DONE", $time);
	endrule

	//******************************************************
	// Deselect all targets. Should be in bus idle already
	//******************************************************
	rule doDeselect if (currState==DESELECT_ALL);
		cen <= 8'hFF;
		//post command wait
		if (postCmdWaitCnt > 0) begin
			currState <= WAIT_CYCLES;
			waitCnt <= postCmdWaitCnt;
			returnState <= IDLE;
		end
		else begin
			currState <= IDLE;
		end
		ctrlCmdQ.deq();
		$display("@%t\t NandPhy: DESELECT_ALL", $time);
	endrule


	//******************************************************
	// Enable clock for sync mode
	//******************************************************
	rule doEnNandClock if (currState==ENABLE_NAND_CLK);
		wenSel <= 0;
		//post command wait
		if (postCmdWaitCnt > 0) begin
			currState <= WAIT_CYCLES;
			waitCnt <= postCmdWaitCnt;
			returnState <= IDLE;
		end
		else begin
			currState <= IDLE;
		end
		ctrlCmdQ.deq();
		$display("@%t\t NandPhy: ENABLE_NAND_CLK", $time);
	endrule


	//******************************************************
	// Sync mode bus idle
	//******************************************************
	rule doSyncBusIdle if (currState==SYNC_CHIP_SEL);
		//one hot encode CE#
		Bit#(4) ce_encoded = ctrlCmdQ.first().nandCmd.ChipSel;
		Bit#(8) cen_one_hot = ~(1 << ce_encoded);
		cen <= cen_one_hot; //CE# low
		ale <= 0;
		cle <= 0;
		wrn <= 1;
		oenDataDQ <= 1;
		iddrRstDQ <= 1; //still keep IDDR in reset
		oenDQS <= 1;
		rstnDQS <= 0; 
		ctrlCmdQ.deq();
		$display("@%t\t NandPhy: SYNC_CHIP_SEL %x", $time, cen_one_hot);
		//wait t_CAD.
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_CAD);
		returnState <= IDLE;
	endrule

	//******************************************************
	// Sync mode command cycle
	//******************************************************
	rule doSyncCommandSet if (currState==SYNC_CMD_SET);
		cle <= 0;
		oenDataDQ <= 0;
		wrDataRise <= pack(ctrlCmdQ.first().nandCmd.OnfiCmd);
		wrDataFall <= pack(ctrlCmdQ.first().nandCmd.OnfiCmd);
		//it takes 2 cycles to appear on DQ
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_CMD_DQ_SYNCREG_DELAY);
		returnState <= SYNC_CMD_LATCH;
		$display("@%t\t NandPhy: SYNC_CMD_SET cmd=%x", $time, ctrlCmdQ.first().nandCmd.OnfiCmd);
	endrule

	rule doSyncCommandLatch if (currState == SYNC_CMD_LATCH);
		cle <= 1;
		currState <= SYNC_DONE;
		$display("@%t\t NandPhy: SYNC_CMD_LATCH", $time);
	endrule

	
	//******************************************************
	// Sync mode address cycle; very similar to cmd cycle
	//******************************************************
	rule doSyncAddrSet if (currState==SYNC_ADDR_SET);
		cle <= 0;
		oenDataDQ <= 0;
		wrDataRise <= addrQ.first();
		wrDataFall <= addrQ.first();
		addrQ.deq();
		//it takes 2 cycles to appear on DQ
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_CMD_DQ_SYNCREG_DELAY);
		returnState <= SYNC_ADDR_LATCH;
		$display("@%t\t NandPhy: SYNC_ADDR_SET addr=%x", $time, addrQ.first());
	endrule

	rule doSyncAddrLatch if (currState == SYNC_ADDR_LATCH);
		ale <= 1; //latch the addr of the PREVIOUS cycle
		//For multiple bursts of addr, setup the next addr on DQ
		if (numBurstCnt == 1) begin
			currState <= SYNC_DONE;
		end
		else begin
			wrDataRise <= addrQ.first();
			wrDataFall <= addrQ.first();
			addrQ.deq();
			currState <= SYNC_ADDR_BURST;
			numBurstCnt <= numBurstCnt - 1;
			$display("@%t\t NandPhy: SYNC_ADDR_LATCH addr=%x", $time, addrQ.first());
		end
	endrule

	rule doSyncAddrBurst if (currState == SYNC_ADDR_BURST);
		ale <= 0;
		//Wait tCAD between bursts
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_CAD);
		returnState <= SYNC_ADDR_LATCH;
		$display("@%t\t NandPhy: SYNC_ADDR_BURST", $time);
	endrule


	//******************************************************************
	// Sync mode read capture timing calibration
	//******************************************************************
	rule doSyncCalibWRLow if (currState==SYNC_CALIB_WR_LOW);
		wrn <= 0;
		numCalibBrCnt <= fromInteger(calibFifoDepth);
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_WRCK_DQSD);
		returnState <= SYNC_CALIB_LATCH;
	endrule
	
	//Enable CLE/ALE for num of cycles of bursts
	//Each burst corresponds to one DDR output (16-bit)
	rule doSyncCalibLatch if (currState==SYNC_CALIB_LATCH);
		if (numBurstCnt>=1) begin
			cle <= 1;
			ale <= 1;
			iddrRstDQ <= 0; //release reset on IDDR so we capture data
			numBurstCnt <= numBurstCnt - 1;
			$display("@%t\t NandPhy: SYNC_CALIB_LATCH asserted cle/ale", $time);
		end
		else begin
			cle <= 0;
			ale <= 0;
		end
	endrule

	//Access window can be 3-20ns after NAND_CLK edge (1 to 2 cycles)
	//Domain transfer regs (2 cycles)
	
	//TODO: set reference calib data values
	//TODO: assert reset on transfer regs so that we start fresh
	//TODO: do we have to calibrate EACH CHIP?

	//Buffer a bunch of data bursts in FIFOs
	rule doSyncCalibCap if (currState==SYNC_CALIB_LATCH);
		if (numCalibBrCnt > 0) begin
			fifoDqR0.enq(vnandPhy.vphyUser.calibDqRise0()); 
			fifoDqR90.enq(vnandPhy.vphyUser.calibDqRise90()); 
			fifoDqR180.enq(vnandPhy.vphyUser.calibDqRise180()); 
			fifoDqR270.enq(vnandPhy.vphyUser.calibDqRise270()); 
			numCalibBrCnt <= numCalibBrCnt-1;
			$display("@%t\t NandPhy: SYNC_CALIB enq'd dqR %x %x %x %x", $time, 
					vnandPhy.vphyUser.calibDqRise0(), vnandPhy.vphyUser.calibDqRise90(), 
					vnandPhy.vphyUser.calibDqRise180(), vnandPhy.vphyUser.calibDqRise270());
		end

		if (numBurstCntBr > 0) begin
			//wait until ddr bursting is done
			numBurstCntBr <= numBurstCntBr-1;
		end

		if (numBurstCntBr==0 && numCalibBrCnt==0) begin
			numCalibBrCnt <= 0;
			//currState <= SYNC_CALIB_CALIBRATE;
			currState <= SYNC_CALIB_DEQ; //TODO testing
			rLat <= 0;
		end
	endrule

	//Calibration procedure
	//1) Sample DQS domain DQ rise data at 0, 90, 180 and 270 degrees 
	//   in cycles 3, 4 and 5
	//2) Find the first valid data
	//3) Use the clock edge 90 to 180 degrees after the first valid byte (clk0 or clk180)
	Reg#(Bit#(8)) dqR0 <- mkReg(0);
	Reg#(Bit#(8)) dqR90 <- mkReg(0);
	Reg#(Bit#(8)) dqR180 <- mkReg(0);
	Reg#(Bit#(8)) dqR270 <- mkReg(0);


	rule doSyncCalibDeq if (currState==SYNC_CALIB_DEQ);
		dqR0 <= fifoDqR0.first();
		dqR90 <= fifoDqR90.first();
		dqR180 <= fifoDqR180.first();
		dqR270 <= fifoDqR270.first();
		fifoDqR0.deq();
		fifoDqR90.deq();
		fifoDqR180.deq();
		fifoDqR270.deq();
		currState <= SYNC_CALIB_CALIBRATE;
	endrule

	rule doSyncCalib if (currState==SYNC_CALIB_CALIBRATE);
			//$display("@%t\t NandPhy: SYNC_CALIB_CALIBRATE", $time);
			//Find the first valid byte
			//if (fifoDqR0.first()==refDqR || fifoDqR90.first()==refDqR) begin
			if (dqR0==refDqR || dqR90==refDqR) begin
				//CLK is 0-180 degrees shifted from DQS
				//Use clk180 to capture data
				calibClk0Sel <= 0; //use clk180 for data capture
				rLat <= rLat+1; //data is available at clk0 on the next edge
				//fifoDqR0.clear();
				//fifoDqR90.clear();
				//fifoDqR180.clear();
				//fifoDqR270.clear();
				currState <= SYNC_DONE;
				$display("@%t\t NandPhy: SYNC_CALIB_CALIBRATE done, clk0sel=0, rLat=%d", $time, rLat);
			end
			//else if (fifoDqR180.first()==refDqR || fifoDqR270.first()==refDqR) begin
			else if (dqR180==refDqR || dqR270==refDqR) begin
				//CLK is 180-360 degrees shifted from DQS
				//Use clk0 at the next cycle edge to capture data
				rLat <= rLat+1;
				calibClk0Sel <= 1;
				//fifoDqR0.clear();
				//fifoDqR90.clear();
				//fifoDqR180.clear();
				//fifoDqR270.clear();
				currState <= SYNC_DONE;
				$display("@%t\t NandPhy: SYNC_CALIB_CALIBRATE done, clk0sel=1, rLat=%d", $time, rLat+1);
			end
			else if (rLat < fromInteger(calibFifoDepth)) begin
				//Check the next cycle
				rLat <= rLat + 1;
				//fifoDqR0.deq();
				//fifoDqR90.deq();
				//fifoDqR180.deq();
				//fifoDqR270.deq();
				currState <= SYNC_CALIB_DEQ;
			end
			else begin
				//Something bad happened. Not capturing data correctly
				$display("@%t\t NandPhy: SYNC_CALIB_CALIBRATE failed. Possible DQ-DQS skew error", $time);
				currState <= SYNC_CALIB_FAIL;
				//TODO: adjust DQ/DQS skew
			end
	endrule

	//******************************************************************
	// Sync mode data output cycle (read from NAND); assume bus idle
	//******************************************************************
	//TODO: not very efficient here. tCAD and tWRCK can overlap
	rule doSyncReadWRLow if (currState==SYNC_READ_WR_LOW);
		wrn <= 0;
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_WRCK_DQSD);
		returnState <= SYNC_READ_LATCH;
	endrule
	
	//Enable CLE/ALE for num of cycles of bursts
	//Each burst corresponds to one DDR output (16-bit)
	rule doSyncReadLatch if (currState==SYNC_READ_LATCH);
		if (numBurstCnt>=1) begin
			cle <= 1;
			ale <= 1;
			iddrRstDQ <= 0; //release reset on IDDR so we capture data
			numBurstCnt <= numBurstCnt - 1;
			$display("@%t\t NandPhy: SYNC_READ_LATCH asserted cle/ale", $time);
		end
		else begin
			cle <= 0;
			ale <= 0;
			//$display("@%t\t NandPhy: SYNC_READ_LATCH DEasserted cle/ale", $time);
		end
	endrule

	//Start capturing data t_DQSCK+t_ISERDES after cle/ale is asserted.
	//Use a separate temp counter here
	rule doSyncReadCap if (currState==SYNC_READ_LATCH);
		//if ((cntRdDelay > fromInteger(t_DQSCK + t_ISERDES)) && numBurstCntBr>=1 ) begin
		if (cntRdDelay >= rLat && numBurstCntBr>=1 ) begin
			let rdRise = vnandPhy.vphyUser.rdDataRiseDQ();
			let rdFall = vnandPhy.vphyUser.rdDataFallDQ();
			syncRdQ.enq({rdRise, rdFall});
			numBurstCntBr <= numBurstCntBr - 1;
			$display("@%t\t NandPhy: SYNC_READ_LATCH sync read data %x %x", $time, rdRise, rdFall);
		end
		else if (numBurstCntBr < 1) begin //we finished reading data bursts
			//wait for ( tCKWR - (t_DQSCK+t_ISERDES) )
			currState <= WAIT_CYCLES;
			waitCnt <= fromInteger(t_CKWR_DQSCK_ISERDES); //TODO not exactly correct
			returnState <= SYNC_DONE;
			cntRdDelay <= 0;
		end
		else begin //waiting rLat
			cntRdDelay <= cntRdDelay+1;
		end
	endrule

	
	//*************************************************************
	// Sync data input cycle (write to NAND); assume bus idle
	//*************************************************************
	rule doSyncWritePreamble if (currState==SYNC_WRITE_PREAMBLE);
		oenDQS <= 0; //enable DQS
		rstnDQS <= 0; //hold DQS low
		oenDataDQ <= 0; //enable DQ
		wrDataRise <= 0; //no real data
		wrDataFall <= 0;
		//hold for t_WPRE
		currState <= WAIT_CYCLES;
		waitCnt <= fromInteger(t_WPRE);
		returnState <= SYNC_WRITE_BURST;
	endrule

	rule doSyncWriteEnable if (currState==SYNC_WRITE_BURST);
		if (numBurstCnt>=1) begin
			cle <= 1;
			ale <= 1;
			numBurstCnt <= numBurstCnt - 1;
			$display("@%t\t NandPhy: SYNC_WRITE_ENABLE asserted cle/ale", $time);
		end
		else begin
			cle <= 0;
			ale <= 0;
			//$display("@%t\t NandPhy: SYNC_WRITE_ENABLE DEasserted cle/ale", $time);
		end
	endrule

	rule doSyncWriteBurst if (currState==SYNC_WRITE_BURST);
		if (numBurstCntBr >= 1) begin
			rstnDQS <= 1;
			Bit#(8) dRise = truncateLSB(syncWrQ.first());
			Bit#(8) dFall = truncate(syncWrQ.first());
			wrDataRise <= dRise;
			wrDataFall <= dFall;
			syncWrQ.deq();
			numBurstCntBr <= numBurstCntBr - 1;
			$display("@%t\t NandPhy: SYNC_WRITE_BURST #%d: %x %x", $time, numBurstCntBr, dRise, dFall);
		end
		else begin
			rstnDQS <= 0;
			wrDataRise <= 0;
			wrDataFall <= 0;
			//hold t_WPST + tDQSS
			currState <= WAIT_CYCLES;
			waitCnt <= fromInteger(t_WPST + t_DQSS);
			returnState <= SYNC_DONE;
		end
	endrule

	//**************************
	// Go bus idle if done (SYNC)
	//**************************
	rule doSyncDone if (currState==SYNC_DONE);
		cle <= 0;
		ale <= 0;
		wrn <= 1;
		oenDataDQ <= 1;
		iddrRstDQ <= 1; //IDDR reset again 
		oenDQS <= 1;
		rstnDQS <= 0;
		ctrlCmdQ.deq();
		//Always wait at least tCAD
		//post command wait
		currState <= WAIT_CYCLES;
		returnState <= IDLE;
		if (postCmdWaitCnt > 0) begin
			waitCnt <= postCmdWaitCnt + fromInteger(t_CAD);
		end
		else begin
			waitCnt <= fromInteger(t_CAD);
		end
		$display("@%t\t NandPhy: SYNC_DONE", $time);
	endrule

	//**************************
	// clk90 domain rules
	//**************************
	//synchronize state to clk90 domain
	/*
	rule syncState;
		currState90<=currState;
	endrule

	//Init in clk90 domain
	rule doInitWait90 if (currState90==INIT_WAIT);
		initDoneSync <= False;
		dlyIncDQSr <= 0;
		dlyCeDQSr <= 0;
		incIdelayDQS_90 <= 0;
	endrule

	rule doAdjIdelayDQS90 if (currState90==ADJ_IDELAY_DQS);
		if (incIdelayDQS_90 != fromInteger(idelayDQS)) begin
			$display("@%t\t NandPhy: incremented dqs idelay", $time);
			dlyIncDQSr <= 1;
			dlyCeDQSr <= 1;
			incIdelayDQS_90 <= incIdelayDQS_90 + 1;
		end
		else begin
			dlyIncDQSr <= 0;
			dlyCeDQSr <= 0;
			initDoneSync <= True;
		end
	endrule
	*/


	//*****************************************************
	// Interface
	//*****************************************************
	
	interface PhyUser phyUser;
		method Action sendCmd (PhyCmd cmd);
			ctrlCmdQ.enq(cmd);
		endmethod

		method Action sendAddr (Bit#(8) addr);
			addrQ.enq(addr);
		endmethod

		method Action asyncWrByte (Bit#(8) data);
			asyncWrQ.enq(data);
		endmethod

		method ActionValue#(Bit#(8)) asyncRdByte();
			asyncRdQ.deq();
			return asyncRdQ.first();
		endmethod

		method ActionValue#(Bit#(16)) syncRdWord();
			syncRdQ.deq();
			return syncRdQ.first();
		endmethod

		method Action syncWrWord (Bit#(16) data);
			syncWrQ.enq(data);
		endmethod

		method Action setDebug (Bit#(8) d);
			debugR <= d;
		endmethod

		method Action setDebug90 (Bit#(8) d);
			debugR90 <= d;
		endmethod

	endinterface

	interface nandPins = vnandPhy.nandPins;


endmodule

