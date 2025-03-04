use contracts::contract_account::{
    IContractAccountDispatcher, IContractAccountDispatcherTrait, IContractAccount,
};
use contracts::kakarot_core::kakarot::KakarotCore::KakarotCoreInternal;
use contracts::kakarot_core::kakarot::StoredAccountType;
use contracts::kakarot_core::{KakarotCore, IKakarotCore};
use evm::errors::{EVMError, CONTRACT_SYSCALL_FAILED};
use evm::model::contract_account::ContractAccountTrait;
use evm::model::{Address, AddressTrait, AccountType};
use openzeppelin::token::erc20::interface::{IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
use starknet::{ContractAddress, EthAddress, get_contract_address};
use utils::helpers::{ResultExTrait, ByteArrayExTrait, compute_starknet_address};


#[derive(Copy, Drop, PartialEq)]
struct Account {
    account_type: AccountType,
    address: Address,
    code: Span<u8>,
    nonce: u64,
    balance: u256,
    selfdestruct: bool,
}

#[derive(Drop)]
struct AccountBuilder {
    account: Account
}

#[generate_trait]
impl AccountBuilderImpl of AccountBuilderTrait {
    fn new(address: Address) -> AccountBuilder {
        AccountBuilder {
            account: Account {
                account_type: AccountType::Unknown,
                address: address,
                code: Default::default().span(),
                nonce: 0,
                balance: 0,
                selfdestruct: false,
            }
        }
    }

    #[inline(always)]
    fn set_type(mut self: AccountBuilder, account_type: AccountType) -> AccountBuilder {
        self.account.account_type = account_type;
        self
    }

    #[inline(always)]
    fn fetch_balance(mut self: AccountBuilder) -> AccountBuilder {
        self.account.balance = self.account.address.fetch_balance();
        self
    }

    #[inline(always)]
    fn fetch_nonce(mut self: AccountBuilder) -> AccountBuilder {
        assert!(
            self.account.account_type == AccountType::ContractAccount,
            "Cannot fetch nonce of an EOA"
        );
        let contract_account = IContractAccountDispatcher {
            contract_address: self.account.address.starknet
        };
        self.account.nonce = contract_account.nonce();
        self
    }

    #[inline(always)]
    fn set_nonce(mut self: AccountBuilder, nonce: u64) -> AccountBuilder {
        self.account.nonce = nonce;
        self
    }

    /// Loads the bytecode of a ContractAccount from Kakarot Core's contract storage into a Span<u8>.
    /// # Arguments
    /// * `self` - The address of the Contract Account to load the bytecode from
    /// # Returns
    /// * The bytecode of the Contract Account as a ByteArray
    fn fetch_bytecode(mut self: AccountBuilder) -> AccountBuilder {
        let contract_account = IContractAccountDispatcher {
            contract_address: self.account.address.starknet
        };
        let bytecode = contract_account.bytecode();
        self.account.code = bytecode;
        self
    }

    #[inline(always)]
    fn build(self: AccountBuilder) -> Account {
        self.account
    }
}

#[generate_trait]
impl AccountImpl of AccountTrait {
    /// Fetches an account from Starknet
    /// An non-deployed account is just an empty account.
    /// # Arguments
    /// * `address` - The address of the account to fetch`
    ///
    /// # Returns
    /// The fetched account if it existed, otherwise a new empty account.
    fn fetch_or_create(evm_address: EthAddress) -> Account {
        let maybe_acc = AccountTrait::fetch(evm_address);

        match maybe_acc {
            Option::Some(account) => account,
            Option::None => {
                let kakarot_state = KakarotCore::unsafe_new_contract_state();
                let starknet_address = kakarot_state.compute_starknet_address(evm_address);
                // If no account exists at `address`, then we are trying to
                // access an undeployed account (CA or EOA). We create an
                // empty account with the correct address and return it.
                AccountBuilderTrait::new(Address { starknet: starknet_address, evm: evm_address })
                    .fetch_balance()
                    .build()
            }
        }
    }

    /// Fetches an account from Starknet
    ///
    /// There is no way to access the nonce of an EOA currently but putting 1
    /// shouldn't have any impact and is safer than 0 since has_code_or_nonce is
    /// used in some places to check collision
    /// # Arguments
    /// * `address` - The address of the account to fetch`
    ///
    /// # Returns
    /// The fetched account if it existed, otherwise `None`.
    fn fetch(evm_address: EthAddress) -> Option<Account> {
        let mut kakarot_state = KakarotCore::unsafe_new_contract_state();
        let maybe_stored_account = kakarot_state.address_registry(evm_address);
        let mut account = match maybe_stored_account {
            Option::Some((
                account_type, starknet_address
            )) => {
                let address = Address { evm: evm_address, starknet: starknet_address };
                match account_type {
                    AccountType::EOA => Option::Some(
                        AccountBuilderTrait::new(address)
                            .set_type(AccountType::EOA)
                            .set_nonce(1)
                            .fetch_balance()
                            .build()
                    ),
                    AccountType::ContractAccount => {
                        let account = AccountBuilderTrait::new(address)
                            .set_type(AccountType::ContractAccount)
                            .fetch_nonce()
                            .fetch_bytecode()
                            .fetch_balance()
                            .build();
                        Option::Some(account)
                    },
                    AccountType::Unknown => Option::None,
                }
            },
            Option::None => Option::None,
        };
        account
    }


    /// Returns whether an account exists at the given address by checking
    /// whether it has code or a nonce.
    ///
    /// Based on the state of the account in the cache - the account can
    /// not be deployed on-chain yet, but already exist in the KakarotState.
    /// The account can also be EVM-undeployed but Starknet-deployed. In that case,
    /// is_known is true, but we should be able to deploy on top of it
    /// # Arguments
    ///
    /// * `account` - The instance of the account to check.
    ///
    /// # Returns
    ///
    /// `true` if an account exists at this address (has code or nonce), `false` otherwise.
    #[inline(always)]
    fn has_code_or_nonce(self: @Account) -> bool {
        if *self.nonce != 0 || !(*self.code).is_empty() {
            return true;
        };
        false
    }

    /// Commits the account to Starknet by updating the account state if it
    /// exists, or deploying a new account if it doesn't.
    ///
    /// Only Contract Accounts can be modified.
    ///
    /// # Arguments
    /// * `self` - The account to commit
    ///
    /// # Returns
    ///
    /// `Ok(())` if the commit was successful, otherwise an `EVMError`.
    fn commit(self: @Account) {
        let is_deployed = self.evm_address().is_deployed();
        let is_ca = self.is_ca();

        // If a Starknet account is already deployed for this evm address, we
        // should "EVM-Deploy" only if the nonce is different.
        let should_deploy = if is_deployed && is_ca {
            let deployed_nonce = ContractAccountTrait::fetch_nonce(self);
            if (deployed_nonce == 0 && deployed_nonce != *self.nonce) {
                true
            } else {
                false
            }
        } else if is_ca {
            // Otherwise, the deploy condition is simply has_code_or_nonce - if the account is a CA.
            self.has_code_or_nonce()
        } else {
            false
        };

        if should_deploy {
            // If SELFDESTRUCT, deploy empty SN account
            let (initial_nonce, initial_code) = if (*self.selfdestruct == true) {
                (0, Default::default().span())
            } else {
                (*self.nonce, *self.code)
            };
            ContractAccountTrait::deploy(
                self.evm_address(),
                initial_nonce,
                initial_code,
                deploy_starknet_contract: !is_deployed
            );
        //Storage is handled outside of the account and must be committed after all accounts are committed.
        //TODO(bug) uncommenting this bugs, needs to be removed when fixed in the compiler
        // return;
        };

        if should_deploy {
            return;
        };

        // If the account was not scheduled for deployment - then update it if it's deployed.
        // Only CAs have components committed on starknet.
        if is_deployed && is_ca {
            if *self.selfdestruct {
                return ContractAccountTrait::selfdestruct(self);
            }
            self.store_nonce(*self.nonce);
        };
    }

    fn commit_storage(self: @Account, key: u256, value: u256) {
        if self.is_selfdestruct() {
            return;
        }
        match self.account_type {
            AccountType::EOA => { panic_with_felt252('EOA account commitment') },
            AccountType::ContractAccount => { self.store_storage(key, value) },
            AccountType::Unknown(_) => { panic_with_felt252('Unknown account commitment') }
        }
    }

    #[inline(always)]
    fn set_balance(ref self: Account, value: u256) {
        self.balance = value;
    }

    #[inline(always)]
    fn balance(self: @Account) -> u256 {
        *self.balance
    }

    #[inline(always)]
    fn address(self: @Account) -> Address {
        *self.address
    }

    #[inline(always)]
    fn is_precompile(self: @Account) -> bool {
        let evm_address: felt252 = self.evm_address().into();
        if evm_address.into() < 0x10_u256 {
            return true;
        }
        false
    }


    /// Returns `true` if the account is a Contract Account (CA).
    #[inline(always)]
    fn is_ca(self: @Account) -> bool {
        match self.account_type {
            AccountType::EOA => false,
            AccountType::ContractAccount => true,
            AccountType::Unknown => false
        }
    }

    #[inline(always)]
    fn evm_address(self: @Account) -> EthAddress {
        *self.address.evm
    }

    #[inline(always)]
    fn starknet_address(self: @Account) -> ContractAddress {
        *self.address.starknet
    }

    /// Returns the bytecode of the EVM account (EOA or CA)
    #[inline(always)]
    fn bytecode(self: @Account) -> Span<u8> {
        *self.code
    }

    /// Fetches the value stored at the given key for the corresponding contract accounts.
    /// If the account is not deployed (in case of a create/deploy transaction), returns 0.
    /// If the account is an EOA, returns 0.
    /// # Arguments
    ///
    /// * `self` The account to read from.
    /// * `key` The key to read.
    ///
    /// # Returns
    ///
    /// A `Result` containing the value stored at the given key or an `EVMError` if there was an error.
    fn read_storage(self: @Account, key: u256, is_deployed: bool) -> u256 {
        if *self.account_type == AccountType::ContractAccount && is_deployed {
            return ContractAccountTrait::fetch_storage(self, key);
        }
        0
    }

    #[inline(always)]
    fn set_type(ref self: Account, account_type: AccountType) {
        self.account_type = account_type;
    }

    /// Sets the nonce of the Account
    /// # Arguments
    /// * `self` The Account to set the nonce on
    /// * `nonce` The new nonce
    #[inline(always)]
    fn set_nonce(ref self: Account, nonce: u64) {
        self.nonce = nonce;
    }

    #[inline(always)]
    fn nonce(self: @Account) -> u64 {
        *self.nonce
    }

    /// Sets the code of the Account
    /// # Arguments
    /// * `self` The Account to set the code on
    /// * `code` The new code
    #[inline(always)]
    fn set_code(ref self: Account, code: Span<u8>) {
        self.code = code;
    }

    /// Registers an account for SELFDESTRUCT
    /// This will cause the account to be erased at the end of the transaction
    #[inline(always)]
    fn selfdestruct(ref self: Account) {
        self.selfdestruct = true;
    }

    /// Returns whether the account is registered for SELFDESTRUCT
    /// `true` means that the account will be erased at the end of the transaction
    #[inline(always)]
    fn is_selfdestruct(self: @Account) -> bool {
        *self.selfdestruct
    }
}
