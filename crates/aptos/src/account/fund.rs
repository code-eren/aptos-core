// Copyright (c) Aptos
// SPDX-License-Identifier: Apache-2.0

use std::time::SystemTime;

use crate::{
    account::create::DEFAULT_FUNDED_COINS,
    common::{
        types::{CliCommand, CliError, CliTypedResult, FaucetOptions, ProfileOptions, RestOptions},
        utils::fund_account,
    },
};
use aptos_types::account_address::AccountAddress;
use async_trait::async_trait;
use clap::Parser;

/// Command to fund an account with tokens from a faucet
///
#[derive(Debug, Parser)]
pub struct FundAccount {
    #[clap(flatten)]
    pub(crate) profile_options: ProfileOptions,
    /// Address to fund
    #[clap(long, parse(try_from_str=crate::common::types::load_account_arg))]
    pub(crate) account: AccountAddress,
    #[clap(flatten)]
    pub(crate) faucet_options: FaucetOptions,
    /// Coins to fund when using the faucet
    #[clap(long, default_value_t = DEFAULT_FUNDED_COINS)]
    pub(crate) num_coins: u64,
    #[clap(flatten)]
    pub(crate) rest_options: RestOptions,
}

#[async_trait]
impl CliCommand<String> for FundAccount {
    fn command_name(&self) -> &'static str {
        "FundAccount"
    }

    async fn execute(self) -> CliTypedResult<String> {
        let hashes = fund_account(
            self.faucet_options
                .faucet_url(&self.profile_options.profile)?,
            self.num_coins,
            self.account,
        )
        .await?;
        let sys_time = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_err(|e| CliError::UnexpectedError(e.to_string()))?
            .as_secs()
            + 10;
        let client = self.rest_options.client(&self.profile_options.profile)?;
        for hash in hashes {
            client.wait_for_transaction_by_hash(hash, sys_time).await?;
        }
        return Ok(format!(
            "Added {} coins to account {}",
            self.num_coins, self.account
        ));
    }
}
