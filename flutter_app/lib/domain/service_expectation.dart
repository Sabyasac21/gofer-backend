import 'service_catalog.dart';

class ServiceExpectation {
  const ServiceExpectation({
    required this.included,
    required this.notIncluded,
    required this.completionOutcome,
  });

  final List<String> included;
  final List<String> notIncluded;
  final String completionOutcome;
}

ServiceExpectation expectationForService(
  ServiceDefinition service, {
  List<String>? included,
  List<String>? notIncluded,
}) {
  final exact = _serviceExpectations[service.id];
  final fallback = exact ??
      switch (service.domainId) {
        'electrical' => _electricalExpectation(service),
        'plumbing' => _plumbingExpectation(service),
        'carpentry' => _carpentryExpectation(service),
        'painting' => _paintingExpectation(service),
        'cleaning' => _cleaningExpectation(service),
        'moving' => _movingExpectation,
        'outdoor' => _outdoorExpectation,
        _ => _generalExpectation(service),
      };
  if (included == null && notIncluded == null) return fallback;
  return ServiceExpectation(
    included: included ?? fallback.included,
    notIncluded: notIncluded ?? fallback.notIncluded,
    completionOutcome: fallback.completionOutcome,
  );
}

const householdHelpExpectation = ServiceExpectation(
  included: [
    'Routine chores you select, worked in your chosen priority order',
    'One verified helper reserved for the booked time block',
    'Reasonable tidying of the immediate work areas before leaving',
  ],
  notIncluded: [
    'Deep cleaning, repairs, hazardous work or heavy lifting',
    'A guarantee that every chore finishes if the selected workload exceeds the booked time',
    'Cleaning supplies or an unapproved extension of time',
  ],
  completionOutcome:
      'Your highest-priority chores are completed first during the reserved time. The helper stops when the booked time ends unless you approve an extension.',
);

const _serviceExpectations = <String, ServiceExpectation>{
  'whole_home_cleaning': ServiceExpectation(
    included: [
      'Dusting and wiping accessible surfaces in the rooms you select',
      'Sweeping or vacuuming and mopping accessible floors',
      'Selected bathroom cleaning and kitchen exterior-surface cleaning',
    ],
    notIncluded: [
      'Inside cabinets or appliances unless explicitly selected and priced',
      'Pest, mould, hazardous waste or permanent stain removal',
      'High exterior windows, heavy furniture moving or post-construction debris',
    ],
    completionOutcome:
        'Selected accessible rooms and surfaces are visibly cleaned to the booked level. Existing damage and stains that cannot be safely removed may remain.',
  ),
  'kitchen_cleaning': ServiceExpectation(
    included: [
      'Degreasing accessible counters, sink, platform and wall tiles',
      'Wiping cabinet and appliance exteriors included in your selection',
      'Sweeping and mopping the accessible kitchen floor',
    ],
    notIncluded: [
      'Inside cabinets, chimney, oven or refrigerator unless selected',
      'Dishwashing, pest treatment or drain and appliance repair',
      'Removal of permanent burns, corrosion or material damage',
    ],
    completionOutcome:
        'The selected kitchen surfaces are wiped, degreased and left tidy; results depend on surface condition and stain age.',
  ),
  'bedroom_cleaning': ServiceExpectation(
    included: [
      'Dusting accessible furniture and room surfaces',
      'Sweeping or vacuuming and mopping accessible floors',
      'Basic room reset around movable everyday items',
    ],
    notIncluded: [
      'Laundry, wardrobe interiors or detailed organisation',
      'Mattress or upholstery wet cleaning unless separately booked',
      'Heavy furniture moving or treatment of pests and mould',
    ],
    completionOutcome:
        'The selected bedrooms are dusted, floor-cleaned and left in a neat everyday condition.',
  ),
  'sofa_cleaning': ServiceExpectation(
    included: [
      'Dry vacuuming of accessible seats, backs and crevices',
      'Material-appropriate spot treatment and extraction where suitable',
      'Basic cleanup of the immediate work area',
    ],
    notIncluded: [
      'Guaranteed removal of permanent stains, dye transfer or odour',
      'Repair of torn fabric, foam, frame or upholstery',
      'Cleaning materials that are unsafe for the declared fabric',
    ],
    completionOutcome:
        'The booked upholstery receives the suitable cleaning process and is left to dry; some stains may improve without disappearing completely.',
  ),
  'mattress_cleaning': ServiceExpectation(
    included: [
      'Vacuuming accessible mattress surfaces and seams',
      'Suitable spot treatment or extraction for the declared mattress',
      'Basic cleanup around the treatment area',
    ],
    notIncluded: [
      'Guaranteed removal of old stains, odours, mould or allergens',
      'Pest or bedbug treatment and mattress repair',
      'Cleaning a mattress that is unsafe to wet-treat',
    ],
    completionOutcome:
        'The selected mattress surfaces are treated with a suitable method and left to dry according to the worker’s guidance.',
  ),
  'carpet_cleaning': ServiceExpectation(
    included: [
      'Dry vacuuming of the selected accessible carpet area',
      'Suitable spot treatment and wet extraction where material permits',
      'Basic cleanup and drying guidance',
    ],
    notIncluded: [
      'Guaranteed removal of permanent stains, fading or odour',
      'Carpet repair, dyeing, pest treatment or delicate-material restoration',
      'Moving heavy furniture or treating inaccessible floor areas',
    ],
    completionOutcome:
        'The selected carpet receives the suitable cleaning process and is left ready to dry.',
  ),
  'window_cleaning': ServiceExpectation(
    included: [
      'Cleaning accessible glass panels on the selected safe side',
      'Wiping accessible frames, tracks and sills',
      'Removing ordinary dust, marks and loose residue',
    ],
    notIncluded: [
      'Unsafe exterior or high-rise access and rope work',
      'Glass scratch, seal, frame or hardware repair',
      'Removal of permanent etching, paint or construction residue unless agreed',
    ],
    completionOutcome:
        'The safely accessible selected glass and frames are wiped clean without requiring hazardous access.',
  ),
  'floor_scrubbing': ServiceExpectation(
    included: [
      'Sweeping or vacuuming the selected accessible floor area',
      'Material-appropriate manual or machine scrubbing',
      'Removal of cleaning residue from the treated area',
    ],
    notIncluded: [
      'Polishing, sealing, crystallisation or floor restoration',
      'Repair of cracks, loose tiles, grout or water damage',
      'Moving heavy furniture or guaranteed removal of permanent stains',
    ],
    completionOutcome:
        'The selected suitable floor area is scrubbed and left free of loose dirt and cleaning residue.',
  ),
  'post_construction_cleaning': ServiceExpectation(
    included: [
      'Removal of fine dust and loose residue from accessible selected areas',
      'Wiping accessible fixtures and surfaces and cleaning floors',
      'Collection of light cleaning waste after loose debris is removed',
    ],
    notIncluded: [
      'Removal or transport of rubble, cement bags or heavy construction waste',
      'Paint, cement or adhesive removal that may damage a surface',
      'Repairs, hazardous material handling or unsafe high-access work',
    ],
    completionOutcome:
        'The agreed accessible areas receive detailed dust cleanup after the site is cleared of construction debris.',
  ),
  'fan_cleaning': ServiceExpectation(
    included: [
      'Dusting and wiping accessible fan blades, body and canopy',
      'Cleaning the stated number and type of safely reachable fans',
      'Basic cleanup of fallen dust below the work area',
    ],
    notIncluded: [
      'Fan repair, rewiring, balancing or replacement parts',
      'Unsafe work at excessive height or inaccessible mounting points',
      'Painting or restoration of rusted or damaged surfaces',
    ],
    completionOutcome:
        'The safely accessible exterior surfaces of the booked fans are free of ordinary dust and loose residue.',
  ),
  'bathroom_cleaning': ServiceExpectation(
    included: [
      'Cleaning the selected toilet, basin, floor and accessible wall tiles',
      'Wiping accessible taps, fittings and exterior surfaces',
      'Rinsing and basic cleanup of the serviced bathroom',
    ],
    notIncluded: [
      'Plumbing repair, drain blockage removal or replacement parts',
      'Permanent hard-water damage, deep mould or pest treatment',
      'Ceiling, tank or unsafe high-access cleaning',
    ],
    completionOutcome:
        'The selected bathroom fixtures and accessible surfaces are cleaned to the booked level and left rinsed and tidy.',
  ),
  'balcony_cleaning': ServiceExpectation(
    included: [
      'Removing loose dust and sweeping the accessible balcony floor',
      'Washing or mopping suitable accessible surfaces when water is available',
      'Wiping accessible railing and ledge interiors',
    ],
    notIncluded: [
      'Unsafe exterior ledges, façade work or work outside protective railings',
      'Bird-net removal, pest treatment or heavy waste disposal',
      'Drain repair, waterproofing or permanent stain restoration',
    ],
    completionOutcome:
        'The safely accessible balcony area is swept and washed or mopped according to the available drainage and water.',
  ),
  'packing_help': ServiceExpectation(
    included: [
      'Sorting and packing the household items you identify',
      'Labelling and arranging packed boxes in the agreed area',
      'Routine handling within the booked time and workload',
    ],
    notIncluded: [
      'Packing materials unless you provide them',
      'Specialist packing of valuables, hazardous goods or fragile artwork',
      'Transport, heavy lifting or dismantling furniture unless separately booked',
    ],
    completionOutcome:
        'Prioritised items are packed using customer-provided materials during the booked helper time.',
  ),
  'moving_assistance': ServiceExpectation(
    included: [
      'Lifting, carrying, loading or unloading the items you declare',
      'The confirmed number of helpers for the booked duration',
      'Reasonable placement of handled items at the agreed pickup or drop area',
    ],
    notIncluded: [
      'Vehicle, driver, packing supplies or transport charges',
      'Dismantling, installation or specialist handling unless separately agreed',
      'Hazardous, undeclared or unsafe-to-lift items',
    ],
    completionOutcome:
        'The declared safe items are handled within the agreed location, helper count and time.',
  ),
};

ServiceExpectation _electricalExpectation(ServiceDefinition service) {
  final lowerName = service.name.toLowerCase();
  final installation = lowerName.contains('installation') ||
      lowerName.contains('setup') ||
      lowerName.contains('mounting');
  final serviceOnly = lowerName.contains('service & cleaning');
  if (installation) {
    return ServiceExpectation(
      included: [
        'Confirming the selected installation point and accessible connections',
        'Standard installation labour for the selected ${service.name.toLowerCase()}',
        'Basic operational and safety check after installation',
      ],
      notIncluded: const [
        'Device, wire, brackets, fittings or other materials and spare parts',
        'New concealed wiring, civil work or changes beyond the selected scope',
        'Work on an unsafe supply or inaccessible mounting area',
      ],
      completionOutcome:
          'The selected item is securely installed at a ready, safe point and its basic operation is checked.',
    );
  }
  if (serviceOnly) {
    return const ServiceExpectation(
      included: [
        'Inspection and cleaning of safely accessible serviceable components',
        'Routine service labour described in the selected booking',
        'Basic operational check after reassembly',
      ],
      notIncluded: [
        'Gas, replacement parts, materials or unrelated repairs',
        'Dismantling that requires specialist workshop work',
        'A guarantee that cleaning alone resolves an existing fault',
      ],
      completionOutcome:
          'Accessible serviceable components are cleaned and the appliance is checked for basic operation.',
    );
  }
  return ServiceExpectation(
    included: [
      'Inspection and diagnosis of the selected ${service.name.toLowerCase()} issue',
      'Standard repair labour within the issue confirmed before work begins',
      'Basic functional and visible safety check after the approved work',
    ],
    notIncluded: const [
      'Spare parts, consumables, gas, wire or replacement equipment',
      'Unrelated faults, concealed wiring, civil work or added scope without approval',
      'Manufacturer warranty work or workshop-level component repair',
    ],
    completionOutcome:
        'The reported issue is diagnosed; any safe in-scope repair is completed after approval and the unit is function-checked.',
  );
}

ServiceExpectation _plumbingExpectation(ServiceDefinition service) =>
    ServiceExpectation(
      included: [
        'Inspection of the reported ${service.name.toLowerCase()} issue',
        'Standard labour on safely accessible fittings within the approved scope',
        'Visible leak or flow check after the approved work',
      ],
      notIncluded: const [
        'Taps, pipes, valves, sealants or other materials and replacement parts',
        'Concealed-pipe tracing, wall or tile breaking and civil restoration',
        'Unrelated fixtures or additional work without your approval',
      ],
      completionOutcome:
          'The agreed accessible plumbing scope is completed and checked for visible leakage or normal flow.',
    );

ServiceExpectation _carpentryExpectation(ServiceDefinition service) =>
    ServiceExpectation(
      included: [
        'Assessment of the selected ${service.name.toLowerCase()} scope',
        'Standard adjustment, repair or fitting labour agreed before work',
        'Alignment and basic function check of the serviced item',
      ],
      notIncluded: const [
        'Wood, laminate, hinges, locks, hardware, polish or other materials',
        'Workshop fabrication, structural alteration or unrelated furniture',
        'Hidden damage or additional work without customer approval',
      ],
      completionOutcome:
          'The approved carpentry scope is completed and the serviced item is checked for alignment and normal use.',
    );

ServiceExpectation _paintingExpectation(ServiceDefinition service) =>
    ServiceExpectation(
      included: [
        'Assessment and basic preparation of the selected ${service.name.toLowerCase()} area',
        'Painting labour for the surface and finish confirmed in the booking',
        'Routine cleanup of tools and loose work residue from the immediate area',
      ],
      notIncluded: const [
        'Paint, primer, putty, masking supplies, scaffolding or other materials',
        'Damp-proofing, structural crack repair or treatment of active leakage',
        'Furniture moving or additional coats and areas not approved in scope',
      ],
      completionOutcome:
          'The agreed prepared area receives the approved finish; final appearance depends on surface condition and selected materials.',
    );

ServiceExpectation _cleaningExpectation(ServiceDefinition service) =>
    ServiceExpectation(
      included: [
        service.shortDescription,
        'Cleaning of safely accessible surfaces selected in the booking',
        'Basic cleanup of the immediate serviced area',
      ],
      notIncluded: const [
        'Repairs, pest treatment, hazardous waste or permanent stain restoration',
        'Unsafe high-access work or moving heavy furniture',
        'Any room, item or specialist treatment not selected in the booking',
      ],
      completionOutcome:
          'The selected accessible surfaces receive the booked cleaning treatment and are left tidy.',
    );

const _movingExpectation = ServiceExpectation(
  included: [
    'Routine handling of the declared safe items',
    'Helpers and labour duration selected in the booking',
    'Loading, unloading or placement within the agreed scope',
  ],
  notIncluded: [
    'Vehicle, fuel, driver, tolls or packing materials',
    'Hazardous goods or undeclared specialist items',
    'Dismantling and installation unless separately approved',
  ],
  completionOutcome:
      'Declared items are handled within the confirmed location, capacity and time.',
);

const _outdoorExpectation = ServiceExpectation(
  included: [
    'Routine work in the selected safely accessible outdoor area',
    'Standard labour and ordinary worker tools for the agreed task',
    'Basic cleanup of loose work residue in the serviced area',
  ],
  notIncluded: [
    'Hazardous access, tree felling, structural or specialist machinery work',
    'Plants, chemicals, disposal fees or other materials',
    'Additional areas or work not confirmed before starting',
  ],
  completionOutcome:
      'The agreed accessible outdoor task is completed within the selected scope and safety limits.',
);

ServiceExpectation _generalExpectation(ServiceDefinition service) =>
    ServiceExpectation(
      included: [
        service.shortDescription,
        'Standard labour for the options confirmed in your booking',
        'A basic completion check with you before the worker leaves',
      ],
      notIncluded: const [
        'Materials, spare parts and third-party charges',
        'Unsafe, specialist or unrelated work',
        'Additional scope that you have not reviewed and approved',
      ],
      completionOutcome:
          'The confirmed service scope is completed and presented to you for review.',
    );
