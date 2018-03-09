# mp1.S - missile-command version
# Good luck, and have fun!

.data
	
    # Constants for accessing the fields of a struct missile, 
    # struct missile is defined in rtc.h and mp1.h

	NEXT 	  = 0
	X	  = 4
	Y	  = 8
	VX	  = 12
	VY	  = 16
	DEST_X	  = 20
	DEST_Y	  = 24
	EXPLODED  = 28
	C	  = 32

	# missile size in bits
	MISSILE_SIZE	= 36

    # Character to draw for an explosion - '@'

	EXPLOSION = 64

	# save edges of game
	LOW_X 	   = 0
	LOW_Y	   = 0
	HIGH_X	   = 79
	HIGH_Y	   = 24
	
	# offsets
	ROW_OFFSET = 160
	COLUMN_OFFSET = 2

	# crosshair starting position
	CROSSHAIR_START_X = 40
	CROSSHAIR_START_Y = 12

	# ASCII values to draw to screen
	CROSSHAIR  = 43 	#crosshair ASCII val --> '+'
	SPACE = 32			# use to draw over finished explosions and moved missiles

	# bitmasks for accessing appropriate bases
	BASE_ALIVE_BITMASK = 0x00FFFFFF		# bitmask for initilizing base at start of game
	BASE_ONE_BITMASK   = 0X000000FF
	BASE_TWO_BITMASK   = 0X0000FF00
	BASE_THREE_BITMASK = 0X00FF0000

	# ioctl vars
	ARG_VAL = 4		# offset of any given first arg on a stack in ioctl
	CMD_VAL	= 8		# offset to access local var cmd in ioctl
	MOVE_CROSSHAIR_BITMAP_HIGH = 0XFFFF0000
	MOVE_CROSSHAIR_BITMAP_LOW  = 0X0000FFFF

	# starting video positions for cities
	BASE_ONE_VIDEO_POS = 3876
	BASE_TWO_VIDEO_POS = 3916
	BASE_THREE_VIDEO_POS = 3956

# Data shared between this file and rtc.c helper functions

# This '.globl' directive makes these symbols visible externally
.globl mp1_missile_list, base_alive, mp1_score

mp1_missile_list:	.long 0x0	# Head of list pointer
base_alive:		.long 0x0	# Array of 3 bytes, plus a padding byte
mp1_score:		.long 0x0	# Player's current score


# Data private to this  file

base_pic:     	    .string "/^^^\\"	# Picture of a live base
dead_base_pic: 	    .string "xxxxx"	# Picture of a dead base
crosshairs_x:		.long 0x0	# X-position of the crosshairs
crosshairs_y:		.long 0x0	# Y-position of the crosshairs

.text

# void mp1_poke(void);
# You can use this function to write to video memory.
#
# Interface: Register-based arguments (not C-style)
#    Inputs: %cl  - The byte you wish to write
#            %eax - Offset from the start of video memory that you wish
#                   to write to
#   Outputs: Text-mode video screen is written to at location %eax with
#            the byte in %cl
# Registers: Clobbers EDX

mp1_poke:
		movl    vmem_base_addr(,1),%edx
		movb    %cl,(%edx,%eax,1)
		ret

#   ----------------- Exported functions ---------------------

# void mp1_rtc_tasklet(unsigned long garbage);
# Performs three tasks:
#	(1) updates the list of missiles (implement this in update_missiles,
#           below, and call it from here).
#	(2) Redraw the bases - they may have been overwritten with missiles
#	(3) Redraw the crosshairs - it may have been overwritten with missiles
# Inputs   : none
# Outputs  : none
# Registers: Standard C calling convention

.globl mp1_rtc_tasklet
mp1_rtc_tasklet:
		pushl	%ebx	#push callee saved registers
		pushl	%esi
		pushl	%edi
		pushl	%edx
		pushl	%eax
		pushl	%ecx
		
		call	update_missiles
		call	rtc_tasklet_redrawCities
		call	rtc_tasklet_redrawCrosshairs
		
		popl 	%ecx 		#pop callee saved registers
		popl 	%eax
		popl	%edx
		popl	%edi
		popl	%esi
		popl	%ebx
		ret

# int mp1_ioctl(unsigned long arg, unsigned int cmd)
# The dispatch function for the MP1 ioctls - should use the cmd argument
# and a jumptable to execute one of the specific ioctls implemented below.
# Inputs   : unsigned long arg - parameter to the mp1_ioctl_....
#          : unsigned int cmd  - specifies which mp1_ioctl_... function 
#          :                     to execute
# Outputs  : Returns an integer - depends on which ioctl() function is called
# Registers: Standard C calling convention

.globl mp1_ioctl
mp1_ioctl:
		#select and run the appropriate I/O control function
		movl CMD_VAL(%esp),%esi 			#access cmd on stack
		cmp $0, %esi
		jl fail_ioctl
		cmp $4, %esi 	# check that cmd is at least 0 and less than or equal to 4
		jg fail_ioctl
		movl $4,%eax 	# multiply esi by 4 to get the appropriate number of bits to move from base of jumptable
		mull %esi 		#transfers data to #eax
		jmp *jump_table(%eax)
		ret

# return -1 if failed to run
fail_ioctl:
		movl $-1, %eax
		ret

# ----------------- Functions private to this file -------------------


# int mp1_ioctl_startgame(unsigned long ignore, unsigned int cmd)
# This function with cmd == 0 instantiates the crosshair position and
# the variable indicating the state of each base as alive
# Inputs   : unsigned long ignore - not needed for this ioctl
#          : unsigned int cmd  - specifies that startgame should be called
# Outputs  : Returns an irrelevant value
# Registers: %edx stores values that need to be updated into variables
mp1_ioctl_startgame:
		# set base alive vals and crosshair values for beginning of game
		movl $BASE_ALIVE_BITMASK,%edx
		movl %edx, base_alive
		
		movl $CROSSHAIR_START_X,%edx
		movl %edx, crosshairs_x
		movl $CROSSHAIR_START_Y,%edx
		movl %edx, crosshairs_y
		ret

# int mp1_ioctl_addmissile(struct missile* user_missile, unsigned int cmd)
# This function with cmd == 1 allocates memory and adds a missile to the kernel space.
# It then adds this missile to our linked list
# Inputs   : struct missile* user_missile - pointer to the userspace missile
#          : unsigned int cmd  - specifies that addmissile should be called
# Outputs  : Returns -1 if failure, 0 if success
# Registers: %eax stores a pointer to the newly allocated memory
#			 %ebx contains the number of bytes that could not be copied
mp1_ioctl_addmissile:

		pushl %ebp
		movl %esp,%ebp
		pushl %ebx
		pushl %esi
		pushl %edi

		# dynamically allocate memory
		pushl 8(%ebp) 				# we want to access the arg val
		pushl $MISSILE_SIZE			# push size of missile struct onto stack as an arg.
		call mp1_malloc
		addl $8,%esp 				# pop 8 bytes off stack
		movl %eax, %ecx
		cmp $0, %eax 				
		je addmissile_fail
		
		# transfer data from user space to kernel space
		pushl %ecx
		pushl $36 			# missile size is 36 bytes
		pushl 8(%ebp) 		# we want to access the arg val
		pushl %eax
		movl %eax,%ecx
		call mp1_copy_from_user
		addl $12,%esp
		popl %ecx
		cmp $0, %eax
		jne addmissile_fail

		# when memory is allocated and data is transferred properly, then add the missile to the list
		movl mp1_missile_list,%edx
		movl %edx,NEXT(%ecx)
		movl %ecx,mp1_missile_list

#		movl 20(%ecx),%eax
#		movl 24(%ecx),%edx
#		movl NEXT(%ecx),%ebx
#		movl -16(%ecx),%esi

		movl $1,%eax
		popl %edi
		popl %esi
		popl %ebx
		leave
		ret

	addmissile_fail:
		movl $-1,%eax	# when pointer is invalid, return -1 (error)
		popl %edi
		popl %esi
		popl %ebx
		leave
		ret

# int mp1_ioctl_movexhairs(unsigned long xhair_delta_packed, unsigned int cmd)
# This function with cmd == 2 moves the crosshairs in the appropriate direction
# and erases the previous crosshair
# Inputs   : unsigned long xhair_delta_packed - high 16 bits store delta y, the low 16 bits store delta x
#          : unsigned int cmd  - specifies that movexhairs should be called
# Outputs  : Returns 0
# Registers: %edi keeps track of where the crosshair should move if an edge is hit
#			 %edx and %ecx keep track of where to move the crosshair if an edge hasn't been hit
mp1_ioctl_movexhairs:
		# first delete the current image of the crosshair (replace it with a space)
		movb $SPACE,%cl
		movl crosshairs_y,%edx
		movl $ROW_OFFSET, %eax
		mull %edx
		movl crosshairs_x,%edx
		shll $1,%edx
		addl %edx,%eax
		call mp1_poke

		# check that the move is legal
		movw ARG_VAL(%esp), %dx
		movw crosshairs_x, %cx
		addw %dx, %cx 		# x + delta(x)
		cmpw $LOW_X, %cx
		jle setCrossHair_left
		cmpw $HIGH_X, %cx
		jge setCrossHair_right
		movl %ecx, crosshairs_x 	#otherwise set crosshairs_x as expected since a wall is not hit
		jmp setY_crossHair

	setCrossHair_left:
			movl $LOW_X, %edi
			movl %edi, crosshairs_x
			jmp setY_crossHair

	setCrossHair_right:
			movl $HIGH_X, %edi
			movl %edi, crosshairs_x

	setY_crossHair:
			# repeat for y coordinate
			movl ARG_VAL(%esp), %edx
			andl $MOVE_CROSSHAIR_BITMAP_HIGH,%edx
			sarl $16, %edx 			# sar maintains the sign of the shift
			movl crosshairs_y, %ecx
			addl %edx, %ecx 		# y + delta(y)
			cmp $LOW_Y, %ecx
			jle setCrossHair_up
			cmp $HIGH_Y, %ecx
			jge setCrossHair_down
			movl %ecx, crosshairs_y 	#otherwise set crosshairs_y as expected since a wall is not hit
			ret

	setCrossHair_up:
			movl $LOW_Y, %edi
			movl %edi, crosshairs_y
			ret

	setCrossHair_down:
			movl $HIGH_Y, %edi
			movl %edi, crosshairs_y
			ret

# int mp1_ioctl_getstatus(unsigned long* user_status, unsigned int cmd)
# This function with cmd == 3 retrieves the score of the player and status of the three
# cities.  The low 16 bits returned are the score, and bits 16,17,18 are the states of the
# first, second, and third cities.  A 1 represents that the city is still alive, a 0 is dead
# Inputs   : unsigned long* user_status - pointer to the user_status output
#          : unsigned int cmd  - specifies that getstatus should be called
# Outputs  : Returns -1 if failure, 0 if success
# Registers: %eax stores the necessary output user_status
#			 %edx contains bitmasks of each city
mp1_ioctl_getstatus:
		movl ARG_VAL(%esp),%eax 	#move arg val to eax to manipulate
		andl $0,%eax 				# clear eax

		# Write the first city's bit to eax (bit 18)
		movl %edx, BASE_THREE_BITMASK
		andl base_alive,%edx
		cmp $0,%edx
		jne GET_BASE_TWO_STATUS
		addl 0x100,%eax 			# corresponds to bit 18 --> will be shifted

		# write the second city's bit to eax (bit 17)
	GET_BASE_TWO_STATUS:
			movl %edx, BASE_TWO_BITMASK
			andl base_alive,%edx
			cmp $0,%edx
			jne GET_BASE_ONE_STATUS
			addl 0x10,%eax 			# corresponds to bit 17 --> will be shifted

			# write the first city's bit to eax (bit 16)
	GET_BASE_ONE_STATUS:
			movl %edx, BASE_ONE_BITMASK
			andl base_alive,%edx
			cmp $0,%edx
			jne UPDATE_SCORE
			addl 0x1,%eax 			# corresponds to bit 16 --> will be shifted

			# add score to complete setting up the user status
	UPDATE_SCORE:
			shll $16, %eax 			# make room for the score
			movl $mp1_score,%edi
			addl %edi,%eax

			movl $1,%ebp			# return '1' to indicate success
			movl ARG_VAL(%esp),%eax
			movl 0(%eax),%eax       # transfer final value to pointer
			ret

# int mp1_ioctl_endgame(unsigned long ignore, unsigned int cmd)
# This function with cmd == 4 frees all heap memory by cycling through the linked list
# Inputs   : unsigned long ignore - an irrelavent value
#          : unsigned int cmd  - specifies that endgame should be called
# Outputs  : Returns 0 for success
# Registers: %ebx is the pointer to the current missile to be deleted
#			 %ecx is the next pointer to delete the next missile
	mp1_ioctl_endgame:
			movl mp1_missile_list,%ebx		#load head of list
			movl NEXT(%ebx),%ecx

	CLEAR_MISSILES:
			# when all missiles are clear, end the game
			cmp $0,%ebx
			je DONE

			# otherwise, delete the current missile and access the next one
			pushl %ebx
			call mp1_free
			popl %ebx
			movl %ecx,%ebx
			movl NEXT(%ebx),%ecx
			jmp CLEAR_MISSILES

	# DONE indicates that the game has ended
	DONE:
			ret

#------------------rtc Helper Functions---------

# void update_missiles()
#       update_missiles checks whether all missiles in the
#       lists are in valid positions and calls to remove all that aren't.
#       It also draws explosions for appropriate missiles
# Inputs   : NONE
# Outputs  : NONE
# Registers: %edi stores the current missile pointer.  All missiles are cycled through
#			 %ecx is the next pointer to delete the next missile
update_missiles:
		pushl %ebp
		movl %esp,%ebp
		pushl %ebx
		pushl %esi
		pushl %edi
		movl mp1_missile_list, %edi	#load head of list
		
# loop to process each missile
	# i) check if missile exists and move the others forward
	# ii) check if bounds are met
	# iii) deal with exploding missiles
	# iv) redraw missiles
	# v) cycle to next missile

check_Missile_Position:		
	# i) check if missile exists and move the others forward
		cmp $0, %edi
		jne update_missile_position
		popl %edi
		popl %esi
		popl %ebx
		leave
		ret

update_missile_position:
		# move missile forward
		movl VX(%edi),%edx
		addl %edx, X(%edi)
		movl VY(%edi),%edx
		addl %edx,Y(%edi)
		movb $SPACE,%cl
		
	# ii) check if bounds are met
checkBounds:
		movl $LOW_X, %ebx	#left side of screen
		movl X(%edi), %ecx
		shrl $16,%ecx
		cmp %ebx, %ecx
		jl mp1_missile_remove
		
		movl $HIGH_X, %ebx	#right side of screen
		jg mp1_missile_remove

		movl $LOW_Y, %ebx	#top of screen
		movl Y(%edi), %ecx
		shrl $16,%ecx
		cmp %ebx, %ecx
		jl mp1_missile_remove

		movl $HIGH_Y, %ebx	#bottom of screen
		jg mp1_missile_remove
	
	# iii) deal with exploding missiles
		# check if missile is currently exploding
		cmp $0, EXPLODED(%edi)
		jne check_exploding_missiles

		# check if missiles should start exploding
		movl DEST_X(%edi),%eax
		cmp %eax, X(%edi)
		jne move_missile_forward	 #if these are not equal, then skip missile_explode call
		movl DEST_Y(%edi),%eax
		cmp %eax, Y(%edi)
		jne move_missile_forward
		
check_exploding_missiles:
		# set up stack frame and call missile_explode
		pushl %edi
		call missile_explode
		addl $4, %esp 
		call mp1_notify_user	#notify user while the stack frame is still created since this must be done anyway
		movl %eax, %ecx			#ecx stores return val from missile_explode

		
		# check if missile should be removed from list
		subl $1,EXPLODED(%edi)	# decrement explosion counter
		cmp $0, EXPLODED(%edi)
		je mp1_missile_remove		# go to next missile if it has finished exploding

		# when not removed, missile should be displayed on monitor
		# first find the appropriate offset for data
		movb $EXPLOSION,%cl
		movl Y(%edi),%edx
		movl $ROW_OFFSET,%eax
		mull %edx	 		#transfers product to eax
		movl X(%edi),%edx
		shrl $16,%edx
		imull $COLUMN_OFFSET,%edx
		addl %edx, %eax
		call mp1_poke

move_missile_forward:
	# iv) redraw missiles

		# redraw missiles
		movb C(%edi),%cl
		movl Y(%edi),%edx
		movl $ROW_OFFSET,%eax
		mull %edx	 		#transfers product to eax
		movl X(%edi),%edx
		shrl $16,%edx
		imull $COLUMN_OFFSET,%edx
		addl %edx, %eax
		call mp1_poke

cycle_next_missile:
	# v) cycle to next missile
		movl NEXT(%edi),%edi
		jmp check_Missile_Position	#reperform for next missile


# void mp1_rtc_tasklet_redrawCities(unsigned long garbage);
# This function:
#		i) checks if a base is alive
#		ii) draws the appropriate base (alive or dead) to each city's position
# Inputs   : garbage
# Outputs  : none
# Registers: %edx: stores bitmasked vals to test which base (alive or dead) to draw
#			 %ebx: counts how many bases still need to be drawn
#			 %esi: counts how many chars have been drawn
#			 %eax: holds video position of what needs to be drawn
#			 %edi: keeps track of the starting position of each base 
rtc_tasklet_redrawCities:
		movl $3,%ebx		#keeps track of the number of bases that need to be drawn (starts at 3)

		# check if the first city is alive and draw it
		movl $0,%esi 	#5 chars still need to be drawn
		movl $BASE_ONE_VIDEO_POS,%eax
		movl $BASE_ONE_BITMASK, %edx
		andl $base_alive,%edx
		cmp $0, %edx
		je draw_dead_base
		cmp $0, %edx 		#CC for flag needs to be reset after calling a function
		jne draw_live_base

draw_second_base:
		# check if the second city is alive and draw it
		movl $0,%esi 	#5 chars still need to be drawn
		movl $BASE_TWO_VIDEO_POS,%eax
		movl $BASE_TWO_BITMASK, %edx
		andl $base_alive,%edx
		cmp $0, %edx
		je draw_dead_base
		cmp $0, %edx 		#CC for flag needs to be reset after calling a function
		jne draw_live_base


draw_third_base:
		# check if the third city is alive and draw it
		movl $0,%esi 	#5 chars still need to be drawn
		movl $BASE_THREE_VIDEO_POS,%eax
		movl $BASE_THREE_BITMASK, %edx
		andl $base_alive,%edx
		cmp $0, %edx
		je draw_dead_base
		cmp $0, %edx 		#CC for flag needs to be reset after calling a function
		jne draw_live_base


draw_dead_base:
		cmp $5,%esi 		#5 chars need to be drawn before we move to the next base
		je determine_next_base
		# otherwise, draw the base
		movb dead_base_pic(,%esi,1),%cl
		pushl %edx 		#save edx which is clobbered i mp1_poke
		call mp1_poke
		popl %edx
		addl $1,%esi 	# update vals for next loop
		addl COLUMN_OFFSET, %eax
		jmp draw_dead_base

draw_live_base:
		cmp $5,%esi 		#5 chars need to be drawn before we move to the next base
		je determine_next_base
		# otherwise, draw the base
		movb base_pic(,%esi,1),%cl
		pushl %edx 		#save edx which is clobbered i mp1_poke
		call mp1_poke
		popl %edx
		addl $1,%esi 	# update vals for next loop
		addl $COLUMN_OFFSET, %eax
		jmp draw_live_base


determine_next_base:
		subl $1,%ebx
		cmp $2,%ebx		#draw second base if ebx is 2
		je draw_second_base
		cmp $1,%ebx 	# else if ebx is 1, draw the third base
		je draw_third_base
		ret 			# otherwise, move on to the next part of the tasklet (drawing crosshairs)

# void mp1_rtc_tasklet_redrawCrosshairs(unsigned long garbage);
# This function:
#		i) draws the crosshairstion
# Inputs   : garbage
# Outputs  : none
# Registers: %edx and %eax are used to determine the appropriate video memory offset
rtc_tasklet_redrawCrosshairs:
		movb $CROSSHAIR,%cl
		movl crosshairs_y,%edx
		movl $ROW_OFFSET, %eax
		mull %edx
		movl crosshairs_x,%edx
		shll $1,%edx
		addl %edx,%eax
		call mp1_poke
		ret

mp1_missile_remove:
		movl $mp1_missile_list,%ecx
		cmp %edi, mp1_missile_list
		jne nextNode
		movl NEXT(%edi),%ecx
		movl %ecx,mp1_missile_list
		pushl %edi
		call mp1_free
		popl %ecx
		jmp cycle_next_missile

nextNode:
		cmpl NEXT(%ecx),%edi
		je remove_node
		movl NEXT(%ecx),%ecx
		jmp nextNode

remove_node:
		movl NEXT(%edi),%esi
		movl %esi,NEXT(%ecx)
		pushl %ecx
		call mp1_free
		popl %ecx
		jmp cycle_next_missile

jump_table: .long mp1_ioctl_startgame, mp1_ioctl_addmissile, mp1_ioctl_movexhairs, mp1_ioctl_getstatus, mp1_ioctl_endgame
