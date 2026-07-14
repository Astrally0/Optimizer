# Luau Optimizer

A lightweight, high-performance, and strictly-typed resource and connection manager for Roblox (`Luau`). It simplifies asset lifecycle management and helps completely eliminate memory leaks by centrally tracking and cleaning up threads, connections, and instances.

## ✨ Features

- **Universal Tracking**: Automatically detects how to clean up `RBXScriptConnection`, `thread`, `Instance`, `function`, or tables with `:Destroy()`/`:Disconnect()`/`:Clean()` (Maid support).
- **Safe Loops**: Native `:Interval()` implementation protected via `pcall` with automated cancellation to prevent game crashes.
- **Transactional Batching**: Support for isolated `:Batch()` transactions. If an error occurs inside a batch, all local allocations are automatically rolled back (cleaned up) without affecting outer scopes.
- **Nested Scoping**: Safely nest multiple batches inside each other with strict error propagation and recovery.
- **Strictly Typed**: Fully written using Luau native types for perfect Luau Language Server integration.

## 🛠️ API Reference

### `Optimizer.new(): Optimizer`
Constructs a new Optimizer manager instance.

### `Optimizer:Add(tag: string?, source: any): any`
Tracks a resource for subsequent cleanup. Returns the passed `source` object for inline assignment.

### `Optimizer:Get(tag: string): any?`
Finds and returns the first tracked object matching the specified tag.

### `Optimizer:Delay(tag: string?, seconds: number, callback: () -> ()): thread`
Executes a callback function once after a specified delay and tracks the generated thread.

### `Optimizer:Interval(tag: string?, seconds: number, callback: () -> ()): thread?`
Spawns a safe infinite loop running a callback every N seconds. **Aborts if seconds <= 0 to prevent game crashes.**

### `Optimizer:BindToHeartbeat(tag: string?, callback: (dt: number) -> ()): () -> ()`
Connects a function to `RunService.Heartbeat` and safely tracks the connection.

### `Optimizer:Remove(source: any): boolean`
Removes and cleans up a specific tracked object by its direct reference.

### `Optimizer:RemoveByTag(tag: string): boolean`
Locates an object by its tag, cleans it up safely, and removes it from the tracker.

### `Optimizer:Batch(callback: (optimizer: Optimizer, tag: string?) -> ())`
Executes a block of code as a single transaction. Automatically rolls back internal tracking allocations on failure. Supports full scoping nesting.

### `Optimizer:CleanUp()`
Cleans up all tracked resources while keeping the Optimizer instance valid for reuse.

### `Optimizer:Destroy()`
Completely dismantles the manager. Cleans up all objects and wipes the internal structure.

## 📄 License
This project is licensed under the MIT License.
