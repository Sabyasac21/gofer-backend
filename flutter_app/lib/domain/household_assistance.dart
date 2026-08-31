class HouseholdWorkloadOption {
  const HouseholdWorkloadOption({
    required this.id,
    required this.label,
    required this.estimatedMinutes,
    required this.description,
  });

  final String id;
  final String label;
  final int estimatedMinutes;
  final String description;
}

class HouseholdChoreDefinition {
  const HouseholdChoreDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.workloads,
  });

  final String id;
  final String name;
  final String description;
  final List<HouseholdWorkloadOption> workloads;

  HouseholdWorkloadOption workload(String id) =>
      workloads.firstWhere((option) => option.id == id);
}

class HouseholdSessionEstimate {
  const HouseholdSessionEstimate({
    required this.effortMinutes,
    required this.recommendedHours,
    required this.exceedsSingleHelperCapacity,
  });

  final int effortMinutes;
  final int recommendedHours;
  final bool exceedsSingleHelperCapacity;
}

class HouseholdSessionPrice {
  const HouseholdSessionPrice({
    required this.durationHours,
    required this.amount,
    required this.rateCardVersion,
  });

  final int durationHours;
  final int amount;
  final String rateCardVersion;
}

class HouseholdBookingQuote {
  const HouseholdBookingQuote({
    required this.id,
    required this.durationHours,
    required this.amount,
    required this.workloadMinutes,
    required this.rateCardVersion,
    required this.expiresAt,
  });

  final String id;
  final int durationHours;
  final int amount;
  final int workloadMinutes;
  final String rateCardVersion;
  final DateTime expiresAt;

  factory HouseholdBookingQuote.fromJson(Map<String, dynamic> json) =>
      HouseholdBookingQuote(
        id: json['id'] as String,
        durationHours: (json['durationHours'] as num).toInt(),
        amount: (json['amount'] as num).toInt(),
        workloadMinutes: (json['workloadMinutes'] as num).toInt(),
        rateCardVersion: json['rateCardVersion'] as String,
        expiresAt: DateTime.parse(json['expiresAt'] as String).toUtc(),
      );
}

class HouseholdSessionPricing {
  const HouseholdSessionPricing._();

  static const rateCardVersion = 'household-help-internal-v1';
  static const _blockRates = <int, int>{1: 249, 2: 449, 3: 649};

  static HouseholdSessionEstimate estimate(
    Map<String, String> selectedWorkloads,
  ) {
    if (selectedWorkloads.isEmpty) {
      return const HouseholdSessionEstimate(
        effortMinutes: 0,
        recommendedHours: 1,
        exceedsSingleHelperCapacity: false,
      );
    }
    var minutes = 10 + (selectedWorkloads.length - 1) * 5;
    for (final entry in selectedWorkloads.entries) {
      final chore = householdChores.firstWhere((item) => item.id == entry.key);
      minutes += chore.workload(entry.value).estimatedMinutes;
    }
    final rawHours = (minutes / 60).ceil();
    return HouseholdSessionEstimate(
      effortMinutes: minutes,
      recommendedHours: rawHours.clamp(1, 3),
      exceedsSingleHelperCapacity: rawHours > 3,
    );
  }

  static HouseholdSessionPrice priceFor(int durationHours) {
    final amount = _blockRates[durationHours];
    if (amount == null) {
      throw ArgumentError.value(durationHours, 'durationHours');
    }
    return HouseholdSessionPrice(
      durationHours: durationHours,
      amount: amount,
      rateCardVersion: rateCardVersion,
    );
  }
}

const householdChores = <HouseholdChoreDefinition>[
  HouseholdChoreDefinition(
    id: 'dishes',
    name: 'Dishes & kitchen reset',
    description: 'Wash utensils, clear the sink and reset accessible counters.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'light',
        label: 'Light load',
        estimatedMinutes: 20,
        description: 'A few utensils from one meal',
      ),
      HouseholdWorkloadOption(
        id: 'regular',
        label: 'Regular load',
        estimatedMinutes: 35,
        description: 'A typical family meal',
      ),
      HouseholdWorkloadOption(
        id: 'heavy',
        label: 'Heavy load',
        estimatedMinutes: 55,
        description: 'Many utensils or greasy cookware',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'floors',
    name: 'Sweep & mop',
    description: 'Routine sweeping and mopping of accessible household floors.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'compact',
        label: '1 RK / compact',
        estimatedMinutes: 30,
        description: 'Studio or compact floor area',
      ),
      HouseholdWorkloadOption(
        id: 'one_bhk',
        label: '1 BHK',
        estimatedMinutes: 45,
        description: 'Routine floor care for a 1 BHK',
      ),
      HouseholdWorkloadOption(
        id: 'two_bhk',
        label: '2 BHK',
        estimatedMinutes: 65,
        description: 'Routine floor care for a 2 BHK',
      ),
      HouseholdWorkloadOption(
        id: 'three_bhk',
        label: '3 BHK',
        estimatedMinutes: 90,
        description: 'Routine floor care for a 3 BHK',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'dusting',
    name: 'Routine dusting',
    description: 'Dust safely accessible furniture and household surfaces.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'few_surfaces',
        label: 'A few surfaces',
        estimatedMinutes: 20,
        description: 'One room or a few furniture surfaces',
      ),
      HouseholdWorkloadOption(
        id: 'one_bhk',
        label: 'Around 1 BHK',
        estimatedMinutes: 35,
        description: 'Accessible surfaces across a small home',
      ),
      HouseholdWorkloadOption(
        id: 'whole_home',
        label: 'Larger home',
        estimatedMinutes: 60,
        description: 'Accessible surfaces across several rooms',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'laundry',
    name: 'Laundry assistance',
    description: 'Help with washing, hanging or folding everyday clothes.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'fold',
        label: 'Fold one basket',
        estimatedMinutes: 20,
        description: 'Clean clothes ready to fold',
      ),
      HouseholdWorkloadOption(
        id: 'machine',
        label: 'Machine & hang',
        estimatedMinutes: 40,
        description: 'Load a machine and hang one basket',
      ),
      HouseholdWorkloadOption(
        id: 'handwash',
        label: 'Hand-wash basket',
        estimatedMinutes: 70,
        description: 'One regular basket of suitable clothes',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'beds',
    name: 'Beds & room reset',
    description: 'Make beds and return everyday items to their place.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'one',
        label: 'One room',
        estimatedMinutes: 15,
        description: 'One bed and a light room reset',
      ),
      HouseholdWorkloadOption(
        id: 'several',
        label: '2–3 rooms',
        estimatedMinutes: 30,
        description: 'Several beds and light tidying',
      ),
      HouseholdWorkloadOption(
        id: 'whole_home',
        label: 'Whole home',
        estimatedMinutes: 50,
        description: 'Beds and light tidying throughout the home',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'organising',
    name: 'Home organising',
    description: 'Arrange a shelf, wardrobe or room using your directions.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'shelf',
        label: 'Shelf / small area',
        estimatedMinutes: 30,
        description: 'One shelf, drawer or small storage area',
      ),
      HouseholdWorkloadOption(
        id: 'wardrobe',
        label: 'One wardrobe',
        estimatedMinutes: 60,
        description: 'Sort and arrange one standard wardrobe',
      ),
      HouseholdWorkloadOption(
        id: 'room',
        label: 'One room',
        estimatedMinutes: 120,
        description: 'A broader room organisation task',
      ),
    ],
  ),
  HouseholdChoreDefinition(
    id: 'packing',
    name: 'Packing & unpacking',
    description: 'Pack or unpack customer-provided boxes and materials.',
    workloads: [
      HouseholdWorkloadOption(
        id: 'few_boxes',
        label: 'Up to 5 boxes',
        estimatedMinutes: 45,
        description: 'A few ordinary household boxes',
      ),
      HouseholdWorkloadOption(
        id: 'one_room',
        label: 'One room',
        estimatedMinutes: 90,
        description: 'Pack or unpack one typical room',
      ),
      HouseholdWorkloadOption(
        id: 'full_home',
        label: 'Full home',
        estimatedMinutes: 240,
        description: 'Requires moving assistance or more capacity',
      ),
    ],
  ),
];
