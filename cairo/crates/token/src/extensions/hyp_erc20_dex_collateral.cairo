// WARNING: This contract is unaudited and should be used at your own risk.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IHypErc20DexCollateral<TContractState> {
    fn get_dex(self: @TContractState) -> starknet::ContractAddress;
    fn get_deposit_token(self: @TContractState) -> starknet::ContractAddress;
    fn balance_on_behalf_of(self: @TContractState, account: ContractAddress) -> u256;
}

#[starknet::contract]
mod HypErc20DexCollateral {
    use alexandria_bytes::Bytes;
    use contracts::client::gas_router_component::GasRouterComponent;
    use contracts::client::mailboxclient_component::MailboxclientComponent;
    use contracts::client::router_component::RouterComponent;
    use contracts::paradex::interface::{IParaclearDispatcher, IParaclearDispatcherTrait};
    use contracts::utils::utils::U256TryIntoContractAddress;
    use contracts::utils::utils::scale_amount;
    use core::array::ArrayTrait;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use openzeppelin::upgrades::interface::IUpgradeable;
    use openzeppelin::upgrades::upgradeable::UpgradeableComponent;
    use starknet::{ContractAddress, syscalls::call_contract_syscall};
    use token::components::{
        hyp_erc20_collateral_component::HypErc20CollateralComponent,
        token_router::{
            TokenRouterComponent, TokenRouterComponent::MessageRecipientInternalHookImpl,
            TokenRouterComponent::{TokenRouterHooksTrait}, TokenRouterTransferRemoteHookDefaultImpl,
        },
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: MailboxclientComponent, storage: mailbox, event: MailBoxClientEvent);
    component!(path: RouterComponent, storage: router, event: RouterEvent);
    component!(path: GasRouterComponent, storage: gas_router, event: GasRouterEvent);
    component!(path: TokenRouterComponent, storage: token_router, event: TokenRouterEvent);
    component!(
        path: HypErc20CollateralComponent, storage: collateral, event: HypErc20CollateralEvent,
    );
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // Ownable
    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    // MailboxClient
    #[abi(embed_v0)]
    impl MailboxClientImpl =
        MailboxclientComponent::MailboxClientImpl<ContractState>;
    impl MailboxClientInternalImpl =
        MailboxclientComponent::MailboxClientInternalImpl<ContractState>;
    // Router
    #[abi(embed_v0)]
    impl RouterImpl = RouterComponent::RouterImpl<ContractState>;
    impl RouterInternalImpl = RouterComponent::RouterComponentInternalImpl<ContractState>;
    // GasRouter
    #[abi(embed_v0)]
    impl GasRouterImpl = GasRouterComponent::GasRouterImpl<ContractState>;
    impl GasRouterInternalImpl = GasRouterComponent::GasRouterInternalImpl<ContractState>;
    // HypERC20Collateral
    #[abi(embed_v0)]
    impl HypErc20CollateralImpl =
        HypErc20CollateralComponent::HypErc20CollateralImpl<ContractState>;
    impl HypErc20CollateralInternalImpl =
        HypErc20CollateralComponent::HypErc20CollateralInternalImpl<ContractState>;
    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;
    // TokenRouter
    #[abi(embed_v0)]
    impl TokenRouterImpl = TokenRouterComponent::TokenRouterImpl<ContractState>;

    #[storage]
    struct Storage {
        dex: ContractAddress,
        #[substorage(v0)]
        collateral: HypErc20CollateralComponent::Storage,
        #[substorage(v0)]
        mailbox: MailboxclientComponent::Storage,
        #[substorage(v0)]
        token_router: TokenRouterComponent::Storage,
        #[substorage(v0)]
        gas_router: GasRouterComponent::Storage,
        #[substorage(v0)]
        router: RouterComponent::Storage,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        HypErc20CollateralEvent: HypErc20CollateralComponent::Event,
        #[flat]
        MailBoxClientEvent: MailboxclientComponent::Event,
        #[flat]
        GasRouterEvent: GasRouterComponent::Event,
        #[flat]
        RouterEvent: RouterComponent::Event,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        TokenRouterEvent: TokenRouterComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        DexDeposit: DexDeposit,
    }

    // An event that is emitted when the DEX deposit is successful (via transfer_to_hook)
    #[derive(Drop, starknet::Event)]
    struct DexDeposit {
        #[key]
        token: ContractAddress,
        #[key]
        recipient: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        mailbox: ContractAddress,
        dex: ContractAddress,
        wrapped_token: ContractAddress,
        owner: ContractAddress,
        hook: ContractAddress,
        interchain_security_module: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self
            .mailbox
            .initialize(mailbox, Option::Some(hook), Option::Some(interchain_security_module));
        self.dex.write(dex);
        self.collateral.initialize(wrapped_token);
    }

    impl TokenRouterHooksTraitImpl of TokenRouterHooksTrait<ContractState> {
        fn transfer_from_sender_hook(
            ref self: TokenRouterComponent::ComponentState<ContractState>, amount_or_id: u256,
        ) -> Bytes {
            HypErc20CollateralComponent::TokenRouterHooksImpl::transfer_from_sender_hook(
                ref self, amount_or_id,
            )
        }

        fn transfer_to_hook(
            ref self: TokenRouterComponent::ComponentState<ContractState>,
            recipient: u256,
            amount_or_id: u256,
            metadata: Bytes,
        ) {
            let recipient: ContractAddress = recipient.try_into().unwrap();

            let mut contract_state = TokenRouterComponent::HasComponent::get_contract_mut(ref self);
            let dex_address = contract_state.dex.read();
            let token_address = contract_state.collateral.wrapped_token.read().contract_address;

            // Get decimals for scaling
            let token_dispatcher = ERC20ABIDispatcher { contract_address: token_address };
            let token_decimals = token_dispatcher.decimals();

            let dex_dispatcher = IParaclearDispatcher { contract_address: dex_address };
            let dex_decimals: u8 = dex_dispatcher.decimals();

            // Scale amount from token decimals to DEX decimals
            let scaled_amount = scale_amount(amount_or_id, token_decimals, dex_decimals);

            // Approve the DEX to spend the tokens (the original amount)
            token_dispatcher.approve(dex_address, amount_or_id);

            // Deposit the tokens (the scaled amount)
            let amount: felt252 = scaled_amount.try_into().unwrap();
            dex_dispatcher.deposit_on_behalf_of(recipient, token_address, amount);

            contract_state
                .emit(DexDeposit { token: token_address, recipient, amount: scaled_amount });
        }
    }


    #[abi(embed_v0)]
    impl HypErc20DexCollateralImpl of super::IHypErc20DexCollateral<ContractState> {
        fn get_dex(self: @ContractState) -> starknet::ContractAddress {
            self.dex.read()
        }

        fn get_deposit_token(self: @ContractState) -> starknet::ContractAddress {
            self.collateral.wrapped_token.read().contract_address
        }

        fn balance_on_behalf_of(self: @ContractState, account: ContractAddress) -> u256 {
            let dex_address = self.dex.read();
            let token_address = self.collateral.wrapped_token.read().contract_address;

            let dex_dispatcher = IParaclearDispatcher { contract_address: dex_address };
            dex_dispatcher.get_token_asset_balance(account, token_address).try_into().unwrap()
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        /// Upgrades the contract to a new implementation.
        /// Callable only by the owner
        /// # Arguments
        ///
        /// * `new_class_hash` - The class hash of the new implementation.
        fn upgrade(ref self: ContractState, new_class_hash: starknet::ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable.upgrade(new_class_hash);
        }
    }
}
