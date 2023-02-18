//! Stop and arithmetic EVM operations

// Core lib imports
use option::OptionTrait;
// Internal imports
use kakarot::stack::StackTrait;
use kakarot::stack::Stack;
use kakarot::context::ExecutionContextTrait;
use kakarot::context::ExecutionContext;


#[derive(Drop, Copy)]
struct StopAndArithmeticOperations {}

trait StopAndArithmeticOperationsTrait {
    /// Return a new instance of the stop and arithmetic operations
    fn new() -> StopAndArithmeticOperations;
    /// Execute an ADD opcode on the current context and updates the context
    fn exec_add(ref self: StopAndArithmeticOperations, ref execution_context: ExecutionContext);
}

impl StopAndArithmeticOperationsImpl of StopAndArithmeticOperationsTrait {
    /// Return a new instance of the stop and arithmetic operations
    #[inline(always)]
    fn new() -> StopAndArithmeticOperations {
        StopAndArithmeticOperations {}
    }

    /// Execute an ADD opcode on the current context and update the context.
    /// # Arguments
    /// * `self` - The stop and arithmetic operations instance
    /// * `execution_context` - The execution context.
    fn exec_add(ref self: StopAndArithmeticOperations, ref execution_context: ExecutionContext) {
        // Deconstruct the execution_context struct so we can mutate the stack
        // TODO: debug `Failed to specialize: `dup<kakarot::context::ExecutionContext>` error
        let ExecutionContext{stack: mut stack, .. } = execution_context;
        // Pop the two inputs
        // TODO update with pop_n
        let a = stack.pop();
        let b = stack.pop();
        match a {
            Option::Some(a) => {
                match b {
                    Option::Some(b) => {
                        // Push the result on the stack and update the execution context
                        stack.push(a + b);
                        execution_context.update_stack(stack);
                    },
                    Option::None(_) => (),
                }
            },
            Option::None(_) => (),
        }
    }
}
