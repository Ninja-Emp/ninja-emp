<?php

declare(strict_types=1);

namespace NinjaEMP\Ledger;

use InvalidArgumentException;
use NinjaEMP\Money\Money;

/**
 * Tender types and their posting behaviour (ADR-0029).
 *
 * A tender is how a sale is paid. Each tender debits a different account:
 *   cash      -> undeposited funds (cash on hand)
 *   check     -> undeposited funds
 *   card      -> card clearing (settles later, net of fees — NOT cash)
 *   gift_cert -> gift certificate control (extinguishes a liability)
 *   store_credit -> customer credit control (extinguishes a liability)
 *   vendor_draw  -> vendor payable control (set-off against money we owe a vendor)
 *
 * The debit role for the first five mirrors the tender_type table; vendor_draw is
 * a distinct tender (a vendor buying with money the store owes them).
 */
final class Tender
{
    public const CASH = 'cash';
    public const CHECK = 'check';
    public const CARD = 'card';
    public const GIFT_CERT = 'gift_cert';
    public const STORE_CREDIT = 'store_credit';
    public const VENDOR_DRAW = 'vendor_draw';

    /** @var array<string, array{role: string, subledger: ?string}> */
    private const MAP = [
        self::CASH => ['role' => 'undeposited_funds', 'subledger' => null],
        self::CHECK => ['role' => 'undeposited_funds', 'subledger' => null],
        self::CARD => ['role' => 'card_clearing', 'subledger' => null],
        self::GIFT_CERT => ['role' => 'gift_certificate_control', 'subledger' => 'gift_certificate'],
        self::STORE_CREDIT => ['role' => 'customer_credit_control', 'subledger' => 'customer_credit'],
        self::VENDOR_DRAW => ['role' => 'vendor_payable_control', 'subledger' => 'vendor_payable'],
    ];

    private function __construct(
        public readonly string $code,
        public readonly Money $amount,
        public readonly ?string $partyId = null,
    ) {
        if (!isset(self::MAP[$this->code])) {
            throw new InvalidArgumentException(sprintf('Unknown tender type: "%s".', $this->code));
        }
    }

    public static function of(string $code, Money $amount, ?string $partyId = null): self
    {
        return new self($code, $amount, $partyId);
    }

    public function debitRole(): string
    {
        return self::MAP[$this->code]['role'];
    }

    public function subledgerTypeCode(): ?string
    {
        return self::MAP[$this->code]['subledger'];
    }

    /**
     * Build the debit line for this tender. Liability tenders (gift cert, store
     * credit, vendor draw) must be tagged to a party subledger.
     */
    public function toJournalLine(): JournalLine
    {
        $subledger = $this->subledgerTypeCode();

        if ($subledger !== null && $this->partyId === null) {
            throw new InvalidArgumentException(sprintf('Tender "%s" requires a party id (subledger-tagged).', $this->code));
        }

        return JournalLine::debit($this->debitRole(), $this->amount, $this->partyId, $subledger);
    }

    /** @return list<string> */
    public static function codes(): array
    {
        return array_keys(self::MAP);
    }
}
