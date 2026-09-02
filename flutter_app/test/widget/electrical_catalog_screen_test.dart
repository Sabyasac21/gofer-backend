import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gofer/data/workida_service_catalog.dart';
import 'package:gofer/domain/pricing_engine.dart';
import 'package:gofer/domain/service_catalog.dart';
import 'package:gofer/screens/dynamic_job_booking_screen.dart';
import 'package:gofer/screens/service_discovery_screen.dart';

void main() {
  Future<void> openElectrical(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: ServiceDiscoveryScreen(
            initialCategory: WorkforceCategory.professional,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Electrical'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Electrical'));
    await tester.pumpAndSettle();
  }

  testWidgets('electrical subsections render as bounded horizontal lists',
      (tester) async {
    await openElectrical(tester);

    for (final collectionId in const [
      'electrical_repairs',
      'electrical_lights_fans',
      'electrical_ac_cooling',
      'electrical_home_appliances',
      'electrical_tv_electronics',
    ]) {
      final finder = find.byKey(ValueKey('professional-section-$collectionId'));
      await tester.scrollUntilVisible(
        finder,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      final list = tester.widget<ListView>(finder);
      expect(list.scrollDirection, Axis.horizontal);
    }
  });

  testWidgets(
      'service card shows central pricing and opens its booking template',
      (tester) async {
    await openElectrical(tester);

    // The card price must come from the central pricing engine, not a literal,
    // so it keeps tracking whatever the admin publishes for this service.
    final service =
        workidaServiceCatalog.serviceById('switch_socket_wiring_repair')!;
    final config = WorkidaPricingCatalog.forService(service);
    final estimate = PricingEngine.calculateEstimate(
      config: config,
      estimatedMinutes: config.estimatedDurationMinMinutes,
    );
    final centralPrice = estimate.estimatedTotal.formatted;

    final priceFinder =
        find.byKey(const ValueKey('service-price-switch_socket_wiring_repair'));
    expect(priceFinder, findsOneWidget);
    expect(
      tester.widget<Text>(priceFinder).data,
      contains(centralPrice),
    );

    await tester.tap(
      find.byKey(const ValueKey('service-card-switch_socket_wiring_repair')),
    );
    await tester.pumpAndSettle();

    // A fixed per-unit service opens the quantity template, never the
    // time-based slider.
    expect(find.byType(DynamicJobBookingScreen), findsOneWidget);
    expect(find.text('Switch, Socket & Wiring Repair'), findsWidgets);
    expect(find.text('Review service details'), findsOneWidget);
    expect(find.text('Quantity (${config.unit})'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('estimated-hours-slider')), findsNothing);
  });
}
