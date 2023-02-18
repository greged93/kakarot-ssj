// Internal imports
use kakarot::context::CallContext;
use kakarot::context::ExecutionContext;
use kakarot::context::ExecutionContextTrait;
use kakarot::stack::Stack;

fn init_execution_context(bytecode: Array::<u8>) -> ExecutionContext {
    let call_data = ArrayTrait::<u8>::new();
    let call_value = 0;
    // Create a call context.
    let call_context = CallContext {
        bytecode: bytecode, call_data: call_data, value: call_value, 
    };
    ExecutionContextTrait::new(call_context)
}

fn init_execution_context_with_stack(stack: Stack) -> ExecutionContext {
    let bytecode = ArrayTrait::<u8>::new();
    let mut execution_context = init_execution_context(bytecode);
    execution_context.update_stack(stack);
    execution_context
}
