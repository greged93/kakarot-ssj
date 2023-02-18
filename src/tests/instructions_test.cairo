// Core lib imports
use option::OptionTrait;
// Internal imports
use kakarot::instructions::stop_and_arithmetic_operations::StopAndArithmeticOperationsTrait;
use kakarot::stack::StackTrait;
use kakarot::tests::test_utils;

#[test]
fn instructions_should_execute_opcode_add() {
    // Given
    let mut stack = StackTrait::new();
    stack.push(integer::u256_from_felt(1));
    stack.push(integer::u256_from_felt(2));
    stack.push(integer::u256_from_felt(3));

    // let mut execution_context = utils::init_execution_context_with_stack(stack);
    let mut stop_arithmetic_operations = StopAndArithmeticOperationsTrait::new();
    // When
    // stop_arithmetic_operations.exec_add(ref execution_context);

    // // Then
    // let expected = integer::u256_from_felt(5);
    // let actual = stack.pop().unwrap();
    // assert(expected == actual, 'incorrect value');
    // let mut stack = execution_context.stack;
    // let actual = stack.peek(0_u32).unwrap();
    // let expected = integer::u256_from_felt(1);
    // assert(expected == actual, 'incorrect value');
}
