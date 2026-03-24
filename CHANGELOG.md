### 1.0.0:
- Moved away from global function calls. You can instead interact with `TopicObjects` 
- Replaced the queue logic from normal roblox array with table.remove/table.insert to Doubly Linked List
- Introduced biased/aging algorithm, to ensure no message stuck in the queue
- Reduces the base message size by a lot, you are now able to send up to 40 messages per batch (previously 10)
- You are no longer limited to "High", "Medium", and "Low". Use `RegisterPriority` to create new priority with custom weight
  
- Fixed duplicate filter not working
- Fixed batching only the first message when the game started

### 0.0.1 [release]
