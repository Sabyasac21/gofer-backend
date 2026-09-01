const RATE_CARD_VERSION = 'workida-in-2026-08-23-v2';
const BLOCK_RATES = Object.freeze({ 1: 199, 2: 398, 3: 597 });

const CHORES = Object.freeze({
  dishes: Object.freeze({ light: 20, regular: 35, heavy: 55 }),
  floors: Object.freeze({ compact: 30, one_bhk: 45, two_bhk: 65, three_bhk: 90 }),
  dusting: Object.freeze({ few_surfaces: 20, one_bhk: 35, whole_home: 60 }),
  laundry: Object.freeze({ fold: 20, machine: 40, handwash: 70 }),
  beds: Object.freeze({ one: 15, several: 30, whole_home: 50 }),
  organising: Object.freeze({ shelf: 30, wardrobe: 60, room: 120 }),
  packing: Object.freeze({ few_boxes: 45, one_room: 90, full_home: 240 }),
});

class HouseholdPricingError extends Error {
  constructor(message, code) {
    super(message);
    this.name = 'HouseholdPricingError';
    this.code = code;
  }
}

function quoteHouseholdSession({ chores, durationHours }) {
  if (!Array.isArray(chores) || chores.length === 0) {
    throw new HouseholdPricingError('Choose at least one household chore.', 'EMPTY_SCOPE');
  }
  const ids = chores.map((chore) => chore.id);
  if (new Set(ids).size !== ids.length) {
    throw new HouseholdPricingError('A chore can only appear once.', 'DUPLICATE_CHORE');
  }

  let workloadMinutes = 10 + ((chores.length - 1) * 5);
  for (const chore of chores) {
    const minutes = CHORES[chore.id]?.[chore.workloadId];
    if (!minutes) {
      throw new HouseholdPricingError(
        `Unsupported workload for ${chore.id}.`,
        'INVALID_WORKLOAD',
      );
    }
    workloadMinutes += minutes;
  }

  const rawRecommendedHours = Math.ceil(workloadMinutes / 60);
  if (rawRecommendedHours > 3) {
    throw new HouseholdPricingError(
      'This workload exceeds one three-hour helper session.',
      'SESSION_CAPACITY_EXCEEDED',
    );
  }
  const recommendedHours = Math.max(1, rawRecommendedHours);
  const amount = BLOCK_RATES[durationHours];
  if (!amount) {
    throw new HouseholdPricingError(
      'Choose a one, two or three-hour session.',
      'INVALID_DURATION',
    );
  }
  if (durationHours < recommendedHours) {
    throw new HouseholdPricingError(
      `${recommendedHours} hours are required for this workload.`,
      'DURATION_TOO_SHORT',
    );
  }

  return {
    rateCardVersion: RATE_CARD_VERSION,
    workloadMinutes,
    recommendedHours,
    durationHours,
    amount,
    chores: chores.map((chore, index) => ({
      id: chore.id,
      workloadId: chore.workloadId,
      priority: index + 1,
    })),
  };
}

module.exports = {
  BLOCK_RATES,
  CHORES,
  HouseholdPricingError,
  RATE_CARD_VERSION,
  quoteHouseholdSession,
};
