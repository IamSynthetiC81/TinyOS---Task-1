#include "SimpleRoutingTree.h"

module SRTreeC
{
	uses interface Boot;
	uses interface SplitControl as RadioControl;
	
	uses interface Timer<TMilli> as LostTaskTimer;

	uses interface Packet as RoutingPacket;
	uses interface AMSend as RoutingAMSend;
	uses interface AMPacket as RoutingAMPacket;
	
	uses interface Packet as DataMaxPacket;
	uses interface AMSend as DataMaxAMSend;
	uses interface AMPacket as DataMaxAMPacket;
	uses interface PacketQueue as DataMaxSendQueue;
	uses interface PacketQueue as DataMaxReceiveQueue;

	uses interface Packet as DataAvgPacket;
	uses interface AMPacket as DataAvgAMPacket;
	uses interface AMSend as DataAvgAMSend;
	uses interface Receive as DataAvgReceive;
	uses interface PacketQueue as DataAvgSendQueue;
	uses interface PacketQueue as DataAvgReceiveQueue;
	

	uses interface Timer<TMilli> as RoutingMsgTimer;
	uses interface Timer<TMilli> as EpochTimer;
	uses interface Timer<TMilli> as SlotTimer;
	
	uses interface Receive as RoutingReceive;
	uses interface Receive as DataMaxReceive;
	
	
	uses interface PacketQueue as RoutingSendQueue;
	uses interface PacketQueue as RoutingReceiveQueue;

	uses interface Random as RandomGenerator;
	uses interface ParameterInit<uint16_t> as GeneratorSeed;
}
implementation
{
	// Epochs
	uint16_t  epochCounter;
	
	message_t radioRoutingSendPkt;
	message_t radioMessageMaxSendPkt;
	message_t radioMessageAvgSendPkt;

	message_t serialPkt;
	message_t serialRecPkt;
	
	 
	bool RoutingSendBusy=FALSE;
	bool NotifySendBusy=FALSE;	 
	bool MessageAvgSendBusy=FALSE;
	bool MessageMaxSendBusy=FALSE;

	bool lostMeasurementSendTask=FALSE;

	uint8_t curdepth;
	uint16_t parentID;
	uint32_t offset;	//Slots time

	uint8_t measurement = 0;

	uint8_t COMMAND_TO_RUN = 0;

	typedef enum command_id{
		COMMAND_MAX = 1,
		COMMAND_AVG = 2,
	} command_id_t;
	
	task void sendRoutingTask();
	task void receiveRoutingTask();
	
	task void startEpoch();
	task void calculateData();
	task void sendMaxDataTask();
	task void sendAvgDataTask();

	void setLostMeasurementSendTask(bool state){
		atomic{
			lostMeasurementSendTask=state;
		}
		call LostTaskTimer.startOneShot(LOST_TASK_PERIOD);
	}

	void setRoutingSendBusy(bool state){
		atomic{
			RoutingSendBusy=state;
		}
	}
	
	void setMessageSendBusy(bool state){
		if(COMMAND_TO_RUN == COMMAND_MAX){ //MAX
			atomic{
				MessageMaxSendBusy=state;
			}
			// dbg("SRTreeC","MessageMaxSendBusy = %s\n", (state == TRUE)?"TRUE":"FALSE");
		}else if(COMMAND_TO_RUN == COMMAND_AVG){   //AVG
			atomic{
				MessageAvgSendBusy=state;
			}
			// dbg("SRTreeC","MessageAvgSendBusy = %s\n", (state == TRUE)?"TRUE":"FALSE");
		}else{
			dbg("SRTreeC","setMessageSendBusy() ERROR\n");
		}

		// to-do
		if (state) call LostTaskTimer.startOneShot(LOST_TASK_PERIOD);
	}
	
	/**
	 * Function to generate a random value between min and max
	 * @param min The minimum value
	 * @param max The maximum value
	 * @return The generated random value
	 */
	uint16_t generateRandomValue(uint16_t min, uint16_t max) {
		return (rand() % (max - min + 1)) + min;
	}

	/**
	 * Function to initialize the sensor value
	 */
	void initializeSensorValue() {
		measurement = generateRandomValue(1, 50);
	}

	/**
	 * Function to update the sensor value
	 */
	void updateSensorValue() {
		int16_t minValue = measurement - (measurement * 30 / 100);
		int16_t maxValue = measurement + (measurement * 30 / 100);

		// Ensure the value stays within 1 and 50
		if (minValue < 1) minValue = 1;
		if (maxValue > 50) maxValue = 50;

		measurement = generateRandomValue(minValue, maxValue);

		dbg("SRTreeC", "updateSensorValue(): New Measurement = %d\n", measurement);
	}

	/**
	 * Function to print the results of the root node
	 * @param count The number of nodes
	 * @param sum The value
	 */
	void rootResults(uint8_t count, uint8_t sum) {
		if (COMMAND_TO_RUN == 1){
			dbg("SRTreeC", "\n\trootResults(): MAX = %d\n\n", sum);
		} else {
			dbg("SRTreeC", "\n\trootResults(): AVG = %f\n\n", (float)sum / count);
		}
	}

	event void Boot.booted(){
		dbg("Boot", "Booted\n");

		// Start the radio control interface to enable communication
		call RadioControl.start();

		epochCounter = 0;

		// Initialize the random number generator
		call GeneratorSeed.init(time(NULL)+TOS_NODE_ID);
		
		// Radio is ready for sending
		setRoutingSendBusy(FALSE);

		if(TOS_NODE_ID==0) {  // Root node initialization
			curdepth=0;
			parentID=0;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);

			// Randomly select the command to run (MAX or AVG)
			if (call RandomGenerator.rand32() % 2 + 1 == 1) {
				dbg("Boot", "Command selected is MAX\n");
				COMMAND_TO_RUN = COMMAND_MAX;
			} else {
				dbg("Boot", "Command selected is AVG\n");
				COMMAND_TO_RUN = COMMAND_AVG;
			}

		} else {  // Non-root node initialization
			curdepth=-1;
			parentID=-1;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
		}

		initializeSensorValue();
	}
	
	event void RadioControl.startDone(error_t err){
		if (err == SUCCESS) {
			dbg("Radio" , "Radio initialized successfully!!!\n");		
			if (TOS_NODE_ID==0){
				call RoutingMsgTimer.startOneShot(500);
			}
		} else {
			dbg("Radio" , "Radio initialization failed! Retrying...\n");
			call RadioControl.start();
		}
	}
	
	event void RadioControl.stopDone(error_t err){ 
		dbg("Radio", "Radio stopped!\n");
	}
	
	event void RoutingMsgTimer.fired(){
		message_t tmp;
		error_t enqueueDone;
		
		RoutingMsg* mrpkt;
		dbg("SRTreeC", "RoutingMsgTimer fired!  radioBusy = %s \n",(RoutingSendBusy)?"True":"False");
		if (TOS_NODE_ID==0){
			dbg("SRTreeC", "\n ##################################### \n");
			dbg("SRTreeC", "#######   ROUTING    ############## \n");
			dbg("SRTreeC", "#####################################\n");
		}
		
		// Check if the routing send queue is full
		if(call RoutingSendQueue.full()){
			dbg("Routing", "RoutingMsgTimer.fired():Routing Send Queue Full...\n");
			return;
		}
		
		// Get a pointer to the payload of the temporary message
		mrpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(RoutingMsg)));
		if(mrpkt==NULL){
			dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
			return;
		}
		atomic{ // Set the current depth and command in the routing message
			mrpkt->depth = curdepth;
			mrpkt->cmd = COMMAND_TO_RUN;
		}
		dbg("SRTreeC" , "Sending RoutingMsg... \n");
	
		// Set the destination of the message to broadcast and the payload length of the message
		call RoutingAMPacket.setDestination(&tmp, AM_BROADCAST_ADDR);
		call RoutingPacket.setPayloadLength(&tmp, sizeof(RoutingMsg));
		
		// Enqueue the message into the routing send queue
		enqueueDone=call RoutingSendQueue.enqueue(tmp);
		
		// Check if the message was enqueued successfully
		if( enqueueDone==SUCCESS){
			if (call RoutingSendQueue.size()==1){
				dbg("SRTreeC","RoutingMsg enqueued successfully in SendingQueue!!!\n");
				post sendRoutingTask();
			}
		} else{
			dbg("SRTreeC","RoutingMsg failed to be enqueued in SendingQueue!!!");
		}
	}
		
	event void EpochTimer.fired() {
		epochCounter++;

		// Stop the experiment after 15 epochs
		if(epochCounter == 15) {
			call RadioControl.stop();
			call EpochTimer.stop();
			return;
		}
		
		dbg("SRTreeC", "Epoch: %d\n", epochCounter);
		
		// Start the window timer of the node
		call SlotTimer.startOneShot(offset - OFFSET_FIX);
	}

	// Timer to send data
	event void SlotTimer.fired() {
		dbg("SRTreeC", "SlotTimer.fired()\n");
		post calculateData();
	}

	// to-do
	event void LostTaskTimer.fired(){
		dbg("SRTreeC", "LostTaskTimer.fired()\n");
		if(lostMeasurementSendTask){
			if(COMMAND_TO_RUN == COMMAND_MAX){
				if(!(call DataMaxSendQueue.empty())){
					post sendMaxDataTask();
					return;
				}
			}else if(COMMAND_TO_RUN == COMMAND_AVG){
				if(!(call DataAvgSendQueue.empty())){
					post sendAvgDataTask();
					return;
				}
			}
			dbg("SRTreeC","LostTaskTimer.fired(): No lost task to be executed");
		}
		
	}

	event void DataMaxAMSend.sendDone(message_t * msg , error_t err){
		dbg("SRTreeC", "A Data Max package sent... %s \n",(err==SUCCESS)?"True":"False");
		setMessageSendBusy(FALSE);

		// Repeat sending messages until DataMaxSendQueue is empty
		if(!(call DataMaxSendQueue.empty())){
			post sendMaxDataTask();
		}
	}

	event void DataAvgAMSend.sendDone(message_t * msg , error_t err){
		dbg("SRTreeC", "A Data Avg package sent... %s \n",(err==SUCCESS)?"True":"False");
		setMessageSendBusy(FALSE);

		// Repeat sending messages until DataAvgSendQueue is empty
		if(!(call DataAvgSendQueue.empty())){
			post sendAvgDataTask();
		}
	}

	event void RoutingAMSend.sendDone(message_t * msg , error_t err){
		// dbg("SRTreeC", "A Routing package sent... %s \n",(err==SUCCESS)?"True":"False");	
		// dbg("SRTreeC" , "Package sent %s \n", (err==SUCCESS)?"True":"False");
		setRoutingSendBusy(FALSE);
		
		// Repeat sending messages until RoutingSendQueue is empty
		if(!(call RoutingSendQueue.empty())){
			post sendRoutingTask();
		}
	}

	event message_t* RoutingReceive.receive( message_t * msg , void * payload, uint8_t len){
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		// Reject message if it hasn't the appropriate size
		if(len!=sizeof(RoutingMsg)){
			dbg("SRTreeC","\t\tUnknown message received!!!\n");
			return msg;
		}
		
		// Copy the received message in tmp and enqueue it to RoutingReceiveQueue
		atomic{
			memcpy(&tmp,msg,sizeof(message_t));
			enqueueDone=call RoutingReceiveQueue.enqueue(tmp);
		}

		// Check if the enqueue operation was successful 
		if(enqueueDone == SUCCESS){
			post receiveRoutingTask();
		} else {
			dbg("SRTreeC","RoutingMsg enqueue failed!!! \n");
		}
		return msg;
	}
	
	event message_t* DataMaxReceive.receive( message_t * msg , void * payload, uint8_t len){
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;

		msource = call DataMaxAMPacket.source(msg);

		dbg("SRTreeC", "DataMax packet received!!!  from %u \n", msource);

		// Reject message if it hasn't the appropriate size
		if(len!=sizeof(DataMaxMsg)){
			dbg("SRTreeC","\t\tUnknown message received!!!\n");
			return msg;
		}
		
		// Copy the received message in tmp and enqueue it to DataMaxReceiveQueue
		atomic{
			memcpy(&tmp,msg,sizeof(message_t));
			enqueueDone=call DataMaxReceiveQueue.enqueue(tmp);
		}

		// Check if the enqueue operation was successful 
		if(enqueueDone != SUCCESS) dbg("SRTreeC","DataMaxMsg enqueue failed!!! \n");
		
		dbg("SRTreeC", "### RoutingReceive.receive() end ##### \n");
		return msg;
	}

	event message_t* DataAvgReceive.receive( message_t * msg , void * payload, uint8_t len){
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;

		msource = call DataAvgAMPacket.source(msg);
		
		dbg("SRTreeC", "DataAvg packet received!!!  from %u \n", msource);
		
		// Reject message if it hasn't the appropriate size
		if(len!=sizeof(DataAvgMsg)){
			dbg("SRTreeC","\t\tUnknown message received!!!\n");
			return msg;
		}
		
		// Copy the received message in tmp and enqueue it to DataAvgReceiveQueue
		atomic{
			memcpy(&tmp,msg,sizeof(message_t));
			enqueueDone=call DataAvgReceiveQueue.enqueue(tmp);
		}
		
		// Check if the enqueue operation was successful 
		if(enqueueDone != SUCCESS) dbg("SRTreeC","DataAvgMsg enqueue failed!!! \n");
		
		return msg;
	}

	////////////// Tasks implementations //////////////////////////////
	
	// Start Epoch
	task void startEpoch(){
		dbg("SRTreeC", "startEpoch()\n");

		//Calculate offset (for sending measurements)
		if(COMMAND_TO_RUN == COMMAND_AVG){
			offset = EPOCH_PERIOD_MILLI-(AVG_STEP*(curdepth));
		}else{
			offset = EPOCH_PERIOD_MILLI-(MAX_STEP*(curdepth));
		}

		// Start window timer
		call SlotTimer.startOneShot(offset - OFFSET_FIX);
		dbg("SRTreeC", "startEpoch(): Started Epoch Timer. Offset Milli = %d\n",offset);

		// Start epoch timer 
		call EpochTimer.startPeriodicAt(0,EPOCH_PERIOD_MILLI);
	}

	task void sendRoutingTask(){
		uint8_t mlen;
		uint16_t mdest;
		error_t sendDone;

		// Check if queue is empty
		if (call RoutingSendQueue.empty()){
			dbg("SRTreeC","sendRoutingTask(): Q is empty!\n");
			return;
		}
		
		//Check if the RoutingAMSend is busy
		if(RoutingSendBusy) {
			dbg("SRTreeC","sendRoutingTask(): RoutingSendBusy= TRUE!!!\n");
			return;
		}
		
		// Dequeue from RoutingSendQueue
		radioRoutingSendPkt = call RoutingSendQueue.dequeue();
		
		// Get the info needed to send the message with RoutingAMSend
		mlen= call RoutingPacket.payloadLength(&radioRoutingSendPkt);
		mdest=call RoutingAMPacket.destination(&radioRoutingSendPkt);

		// Check if the message has the appropriate size
		if(mlen!=sizeof(RoutingMsg)) {
			dbg("SRTreeC","\t\tsendRoutingTask(): Unknown message!!!\n");
			return;
		}

		// Send the message with RoutingAMSend
		sendDone=call RoutingAMSend.send(mdest,&radioRoutingSendPkt,mlen);
		
		// Check if the message was sent successfully and set the flag Busy to true
		if ( sendDone== SUCCESS) {
			// dbg("SRTreeC","sendRoutingTask(): Send returned success!!!\n");
			setRoutingSendBusy(TRUE);
		}
		else {
			dbg("SRTreeC","send failed!!!\n");
		}

		// Start the epoch after the routing message is sent 
		post startEpoch();
	}

	task void receiveRoutingTask() {
		message_t tmp;
		uint8_t len;
		uint16_t SID;
		message_t radioRoutingRecPkt;
		
		// Dequeue the message from RoutingReceiveQueue
		radioRoutingRecPkt= call RoutingReceiveQueue.dequeue();
		
		// Get its length
		len= call RoutingPacket.payloadLength(&radioRoutingRecPkt);
		
		// dbg("SRTreeC","ReceiveRoutingTask(): len=%u \n",len);
		
		// Processing of radioRoutingRecPkt				
		if(len == sizeof(RoutingMsg)){
			
			// Get the payload of the message
			RoutingMsg * mpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));

			// Get the source of the message
			SID = call RoutingAMPacket.source(&radioRoutingRecPkt);

			// dbg("SRTreeC" , "receiveRoutingTask():senderID= %d , depth= %d \n", SID , mpkt->depth);
			
			// Case when the node has no parent
			if ( (parentID<0)||(parentID>=65535)) {
				
				// Set the info needed for the node
				parentID= SID;
				curdepth= mpkt->depth + 1;
				COMMAND_TO_RUN = mpkt->cmd;
				
				// Begin routing timer if it's a non-root node
				if (TOS_NODE_ID!=0){
					call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
				}

			} else { //case where the node has already a parent, but found one that it's closer to
				if (( curdepth > mpkt->depth +1)){					
			
					parentID= call RoutingAMPacket.source(&radioRoutingRecPkt);//mpkt->senderID;
					curdepth = mpkt->depth + 1;
					
					// Begin routing timer if it's a non-root node
					if (TOS_NODE_ID!=0){
						call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
					}
				}
			}
		}
		else{ // Wrong size of message
			dbg("SRTreeC","receiveRoutingTask():Empty message!!! \n");
			return;
		}
	}

	task void calculateData() {
		message_t tmp;

		dbg("SRTreeC", "calculateData()\n");

		if (COMMAND_TO_RUN == 1) {  // MAX
			// If DataMaxReceiveQueue is empty then send measurement to parent
			if (call DataMaxReceiveQueue.empty()) {
				
				// Create the message, we need to send
				DataMaxMsg* mpkt = (DataMaxMsg*) (call DataMaxPacket.getPayload(&tmp, sizeof(DataMaxMsg)));

				dbg("SRTreeC", "calculateData(): No Data Received!!!\n");

				atomic {
					mpkt->data = measurement;
				}

				call DataMaxAMPacket.setDestination(&tmp, parentID);
				call DataMaxPacket.setPayloadLength(&tmp, sizeof(DataMaxMsg));

				dbg("SRTreeC", "calculateData(): Sending Measurement [%d] to Parent %d \n", measurement, parentID);

				// Check if the enqueue operation was successful
				if (call DataMaxSendQueue.enqueue(tmp) == SUCCESS) {
					dbg("SRTreeC", "calculateData(): DataMaxMsg enqueued in SendingMaxQueue successfully!!!\n");
					post sendMaxDataTask();
				} else {
					dbg("SRTreeC", "calculateData(): DataMaxMsg failed to be enqueued in SendingMaxQueue!!!\n");
				}
			} else { // If DataMaxReceiveQueue is not empty
				DataMaxMsg* mpkt;
				uint8_t max;

				max = measurement;

				// Iterate through DataMaxReceiveQueue and dequeue every message,
				// comparing their value to current value of the node
				while (!call DataMaxReceiveQueue.empty()) {
					message_t radioDataReceivePkt = call DataMaxReceiveQueue.dequeue();
					uint8_t len = call DataMaxPacket.payloadLength(&radioDataReceivePkt);
					uint16_t msource = call DataMaxAMPacket.source(&radioDataReceivePkt);


					if (len != sizeof(DataMaxMsg)) {
						dbg("SRTreeC", "calculateData(): Unknown message received!!!\n");
						continue;
					}

					mpkt = (DataMaxMsg*) (call DataMaxPacket.getPayload(&radioDataReceivePkt, len));
					if (mpkt->data > max) {
						max = mpkt->data;
					}

					dbg("SRTreeC", "calculateData(): Data Received from %d: Value = %d\n", msource, mpkt->data);
				}

				// If root node, print the results
				if (TOS_NODE_ID == 0) {
					dbg("SRTreeC", "calculateData(): Sending Results to PC\n");
					rootResults(0, max);
				} else { // If non-root node send data to parent
					mpkt = (DataMaxMsg*) (call DataMaxPacket.getPayload(&tmp, sizeof(DataMaxMsg)));

					atomic {
						mpkt->data = max;
					}
					call DataMaxAMPacket.setDestination(&tmp, parentID);
					call DataMaxPacket.setPayloadLength(&tmp, sizeof(DataMaxMsg));

					// Check if the enqueue operation was successful
					if (call DataMaxSendQueue.enqueue(tmp) == SUCCESS) {
						dbg("SRTreeC", "calculateData(): DataMaxMsg enqueued in SendingQueue successfully!!!\n");
						post sendMaxDataTask();
					} else {
						dbg("SRTreeC", "calculateData(): DataMaxMsg failed to be enqueued in SendingQueue!!!\n");
					}
				}
			}
		} else {  // AVG

			// If DataAvgReceiveQueue is empty then send measurement to parent
			if (call DataAvgReceiveQueue.empty()) {

				// Create the message, we need to send

				DataAvgMsg* mpkt = (DataAvgMsg*) (call DataAvgPacket.getPayload(&tmp, sizeof(DataAvgMsg)));

				dbg("SRTreeC", "calculateData(): No Data Received!!!\n");

				atomic {
					mpkt->Sum = measurement;
					mpkt->Count = 1;
				}

				call DataAvgAMPacket.setDestination(&tmp, parentID);
				call DataAvgPacket.setPayloadLength(&tmp, sizeof(DataAvgMsg));

				dbg("SRTreeC", "calculateData(): Sending Measurement [%d] to Parent %d \n", measurement, parentID);

				// Check if the enqueue operation was successful
				if (call DataAvgSendQueue.enqueue(tmp) == SUCCESS) {
					dbg("SRTreeC", "calculateData(): DataAvgMsg enqueued in SendingAvgQueue successfully!!!\n");
					post sendAvgDataTask();
				} else {
					dbg("SRTreeC", "calculateData(): DataAvgMsg failed to be enqueued in SendingAvgQueue!!!\n");
				}
			} else { // If DataAvgReceiveQueue is not empty
				DataAvgMsg* mpkt;
				uint16_t sum;
				uint16_t ChildCount;
				uint8_t len;
				uint16_t msource;
				uint16_t encodedValue;
				uint16_t sumValue;
				uint16_t countValue;
				// dbg("SRTreeC", "calculateData(): Calculating AVG\n");

				sum = measurement;
				ChildCount = 1;

				// Iterate through DataAvgReceiveQueue and dequeue every message,
				// adding their value to the total sum of the node, as also the
				// their children count to the children count of the node 
				while (!call DataAvgReceiveQueue.empty()) {
					atomic{
						radioMessageAvgSendPkt = call DataAvgReceiveQueue.dequeue();
					}
					len = call DataAvgPacket.payloadLength(&radioMessageAvgSendPkt);
					msource = call DataAvgAMPacket.source(&radioMessageAvgSendPkt);

					encodedValue = 0;

					sumValue=0;
					countValue=0;

					if (len != sizeof(DataAvgMsg)) {
						dbg("SRTreeC", "calculateData(): Unknown message received!!!\n");
						continue;
					}

					mpkt = (DataAvgMsg*) (call DataAvgPacket.getPayload(&radioMessageAvgSendPkt, len));
					sumValue = mpkt->Sum;
					countValue = mpkt->Count;
					
					dbg("SRTreeC", "calculateData(): Data Received from %d: ChildCount = %d : Sum = %d\n", msource, countValue,sumValue );
				
					sum += sumValue;
					ChildCount += countValue;
				}

				// If root node, print the results
				if (TOS_NODE_ID == 0) {
					dbg("SRTreeC", "calculateData(): Sending Results to PC\n");
					rootResults(ChildCount, sum);
				} else { // If non-root node send data to parent
					mpkt = (DataAvgMsg*) (call DataAvgPacket.getPayload(&tmp, sizeof(DataAvgMsg)));

					atomic {
						mpkt->Sum = sum;
						mpkt->Count = ChildCount;
					}
					call DataAvgAMPacket.setDestination(&tmp, parentID);
					call DataAvgPacket.setPayloadLength(&tmp, sizeof(DataAvgMsg));

					// Check if the enqueue operation was successful
					if (call DataAvgSendQueue.enqueue(tmp) == SUCCESS) {
						dbg("SRTreeC", "calculateData(): DataAvgMsg enqueued in SendingQueue successfully!!!\n");
						post sendAvgDataTask();
					} else {
						dbg("SRTreeC", "calculateData(): DataAvgMsg failed to be enqueued in SendingQueue!!!\n");
					}
				}
			}
		}

		// Change the value of the node for the next epoch
		updateSensorValue();
	}

	task void sendMaxDataTask() {
		uint8_t mlenMax;
		uint16_t mdestMax;
		error_t sendDone;

		// If root node do nothing
		if (curdepth == 0) {
			dbg("SRTreeC", "sendMaxDataTask(): ParentID reached!!!\n");
			return;
		}

		//Check if the DataMaxSendQueue is empty
		if (call DataMaxSendQueue.empty()) {
			dbg("SRTreeC", "sendMaxDataTask(): Q is empty!\n");
			return;
		}

		// If busy flag true then do nothing
		if (MessageMaxSendBusy) {
			dbg("SRTreeC", "sendMaxDataTask(): MessageMaxSendBusy= TRUE!!!\n");
			return;
		}

		// Dequeue the message from the DataMaxSendQueue
		atomic {
			radioMessageMaxSendPkt = call DataMaxSendQueue.dequeue();
		}

		// Get the info needed to send the message with the DataMaxAMSend
		mlenMax = call DataMaxPacket.payloadLength(&radioMessageMaxSendPkt);
		mdestMax = call DataMaxAMPacket.destination(&radioMessageMaxSendPkt);

		if (mlenMax != sizeof(DataMaxMsg)) {
			dbg("SRTreeC", "\t\tsendMaxDataTask(): Unknown message!!!\n");
			return;
		}

		setMessageSendBusy(TRUE);
		sendDone = call DataMaxAMSend.send(mdestMax, &radioMessageMaxSendPkt, mlenMax);

		dbg("SRTreeC", "sendMaxDataTask(): %s\n", (sendDone == SUCCESS) ? "Send returned success!!!" : "Send failed!!!");
	}

	task void sendAvgDataTask(){
		uint8_t mlenAvg;
		uint16_t mdestAvg;
		error_t sendDone;

		dbg("SRTreeC", "sendAvgDataTask()\n");

		// If root node do nothing
		if (curdepth == 0) {
			dbg("SRTreeC", "sendMaxDataTask(): ParentID reached!!!\n");
			return;
		}

		//Check if the DataAvgSendQueue is empty
		if (call DataAvgSendQueue.empty()) {
			dbg("SRTreeC", "sendAvgDataTask(): Q is empty!\n");
			return;
		}

		// If busy flag true then do nothing
		if (MessageAvgSendBusy) {
			dbg("SRTreeC", "sendAvgDataTask(): MessageAvgSendBusy= TRUE!!!\n");
			setLostMeasurementSendTask(TRUE);
			return;
		}
		
		// Dequeue the message from the DataAvgSendQueue
		atomic{
			radioMessageAvgSendPkt = call DataAvgSendQueue.dequeue();
		}
		
		// Get the info needed to send the message with the DataAvgAMSend
		mlenAvg= call DataAvgPacket.payloadLength(&radioMessageAvgSendPkt);
		mdestAvg=call DataAvgAMPacket.destination(&radioMessageAvgSendPkt);

		if(mlenAvg!=sizeof(DataAvgMsg)) {
			dbg("SRTreeC","\t\tsendAvgDataTask(): Unknown message!!!\n");
			return;
		}

		setMessageSendBusy(TRUE);
		sendDone=call DataAvgAMSend.send(mdestAvg,&radioMessageAvgSendPkt,mlenAvg);
		
		dbg("SRTreeC", "sendAvgDataTask(): %s\n", (sendDone == SUCCESS) ? "Send returned success!!!" : "Send failed!!!");
	}
}