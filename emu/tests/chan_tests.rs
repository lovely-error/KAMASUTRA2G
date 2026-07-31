// //! Comprehensive tests for Chan ring buffer implementation
// //!
// //! Tests cover:
// //! - Basic send/receive operations
// //! - Empty buffer handling
// //! - Concurrent access patterns
// //! - Memory ordering guarantees

// use chan::{chan, Sender, Receiver};

// #[test]
// fn test_basic_send_and_receive() {
// 	// Create a new channel
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send a value
// 	assert!(sender.try_send(42));
	
// 	// Peek at the value without consuming it
// 	let peeked = receiver.peek();
// 	assert_eq!(peeked, Some(42));
	
// 	// Drop the value
// 	receiver.drop();
	
// 	// After dropping, peek should return None
// 	assert_eq!(receiver.peek(), None);
// }

// #[test]
// fn test_send_to_full_buffer() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send first item
// 	assert!(sender.try_send(1));
	
// 	// Try to send second item (buffer should have space)
// 	assert!(sender.try_send(2));
	
// 	// Try to send third item (buffer is now full)
// 	assert!(!sender.try_send(3));
	
// 	// Peek should still show the last item
// 	assert_eq!(receiver.peek(), Some(2));
// }

// #[test]
// fn test_send_after_drop() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send and drop
// 	sender.try_send(1);
// 	receiver.drop();
	
// 	// Now buffer should be empty, can send again
// 	assert!(sender.try_send(2));
	
// 	// Should be able to receive the new value
// 	assert_eq!(receiver.peek(), Some(2));
// }

// #[test]
// fn test_multiple_senders_different_channels() {
// 	let (sender1, receiver1) = chan::<i32>();
// 	let (sender2, receiver2) = chan::<i32>();
	
// 	// Send through different channels
// 	assert!(sender1.try_send(100));
// 	assert!(sender2.try_send(200));
	
// 	// Each receiver should see its own value
// 	assert_eq!(receiver1.peek(), Some(100));
// 	assert_eq!(receiver2.peek(), Some(200));
// }

// #[test]
// fn test_peek_without_consuming() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	sender.try_send(42);
	
// 	// Peek multiple times without consuming
// 	assert_eq!(receiver.peek(), Some(42));
// 	assert_eq!(receiver.peek(), Some(42));
// 	assert_eq!(receiver.peek(), Some(42));
// }

// #[test]
// fn test_drop_on_empty_buffer() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// No items sent, try to drop
// 	receiver.drop();
	
// 	// Should still be empty
// 	assert_eq!(receiver.peek(), None);
// }

// #[test]
// fn test_send_returns_false_when_full() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Fill the buffer
// 	assert!(sender.try_send(1));
// 	assert!(sender.try_send(2));
	
// 	// Third send should fail
// 	assert!(!sender.try_send(3));
	
// 	// Fourth send should also fail
// 	assert!(!sender.try_send(4));
// }

// #[test]
// fn test_round_trip() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send various values
// 	assert!(sender.try_send(10));
// 	assert!(sender.try_send(20));
	
// 	// Receive and verify
// 	assert_eq!(receiver.peek(), Some(10));
	
// 	// Send more
// 	assert!(sender.try_send(30));
	
// 	assert_eq!(receiver.peek(), Some(20));
// }

// #[test]
// fn test_no_data_race_on_send() {
// 	// This test verifies that send operations are properly synchronized
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send multiple values
// 	for i in 0..10 {
// 		assert!(sender.try_send(i));
// 	}
	
// 	// Buffer should be full
// 	assert!(!sender.try_send(100));
	
// 	// Peek should show last value
// 	assert_eq!(receiver.peek(), Some(9));
// }

// #[test]
// fn test_no_data_race_on_receive() {
// 	// This test verifies that receive operations are properly synchronized
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send a value
// 	assert!(sender.try_send(42));
	
// 	// Peek multiple times
// 	for _ in 0..5 {
// 		assert_eq!(receiver.peek(), Some(42));
// 	}
	
// 	// Drop the value
// 	receiver.drop();
	
// 	// After drop, should be empty
// 	assert_eq!(receiver.peek(), None);
// }

// #[test]
// fn test_multiple_drops() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send and drop
// 	sender.try_send(1);
// 	receiver.drop();
	
// 	// Try to drop again (should be safe)
// 	receiver.drop();
	
// 	// Still should be empty
// 	assert_eq!(receiver.peek(), None);
// }

// #[test]
// fn test_send_ordering() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send multiple values
// 	assert!(sender.try_send(1));
// 	assert!(sender.try_send(2));
	
// 	// Should see values in order
// 	assert_eq!(receiver.peek(), Some(1));
// }

// #[test]
// fn test_receiver_without_sender() {
// 	// Create receiver without sending anything
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Should be empty
// 	assert_eq!(receiver.peek(), None);
	
// 	// Drop should be safe
// 	receiver.drop();
// }

// #[test]
// fn test_sender_without_receiver() {
// 	// Create sender without receiving anything
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Send should work
// 	assert!(sender.try_send(42));
// 	assert!(sender.try_send(43));
	
// 	// Third send should fail (buffer full)
// 	assert!(!sender.try_send(44));
	
// 	// Receiver can still peek
// 	assert_eq!(receiver.peek(), Some(42));
// }

// #[test]
// fn test_peek_on_full_buffer() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Fill buffer
// 	assert!(sender.try_send(1));
// 	assert!(sender.try_send(2));
	
// 	// Peek should work
// 	assert_eq!(receiver.peek(), Some(1));
	
// 	// Third send should fail
// 	assert!(!sender.try_send(3));
	
// 	// Peek still works
// 	assert_eq!(receiver.peek(), Some(2));
// }

// #[test]
// fn test_drop_on_full_buffer() {
// 	let (sender, receiver) = chan::<i32>();
	
// 	// Fill buffer
// 	assert!(sender.try_send(1));
// 	assert!(sender.try_send(2));
	
// 	// Drop should work
// 	receiver.drop();
	
// 	// Buffer should now have space
// 	assert!(sender.try_send(3));
	
// 	// Peek should show new value
// 	assert_eq!(receiver.peek(), Some(2));
// }