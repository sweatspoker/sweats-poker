import {
  SettlementReceiptCard,
  type Receipt,
} from "@/components/SettlementReceiptCard";

// Below-fold "Settlement at cashout" feature. Renders the EXACT same
// <SettlementReceiptCard> the live app pops in the settlement modal,
// populated with mock data so visitors see proof-of-payout in the
// same UI they'll see when their own player cashes out.
const mockReceipt: Receipt = {
  offering_id: "preview-tommy-ho",
  stream_name: "Friday Night Cash · Palace Poker",
  venue_name: "Palace Poker",
  player_id: "tommy_ho",
  player_display_name: "Tommy Ho",
  player_photo_url: null,
  session_started_at: new Date(Date.now() - 4 * 3600 * 1000).toISOString(),
  settled_at: new Date().toISOString(),
  duration_seconds: 4 * 3600,
  total_shares: 5000,
  final_chip_stack_minor: 820_000, // $8,200
  final_share_value_minor: 164, // 1.64 SC/share
  declared_buyin_minor: 500_000, // $5,000 buy-in
  shares_held: 350,
  weighted_avg_cost_minor: 110, // 1.10 SC/share avg cost
  cost_basis_minor: 38_500,
  payout_minor: 57_400,
  pnl_minor: 18_900,
  pnl_pct: 49.1,
};

export function SettlementReceipt() {
  return (
    <div className="max-w-md mx-auto">
      <SettlementReceiptCard r={mockReceipt} />
    </div>
  );
}
