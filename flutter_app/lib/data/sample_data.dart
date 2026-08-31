import 'package:flutter/material.dart';

import '../models/taskr_models.dart';

const serviceCategories = [
  ServiceCategory(
    id: 'electrician',
    name: 'Electrician',
    icon: Icons.electrical_services_outlined,
    averageRate: 450,
    description: 'Switches, wiring, fans, power issues',
    color: Color(0xFFFFB020),
  ),
  ServiceCategory(
    id: 'plumber',
    name: 'Plumber',
    icon: Icons.plumbing_outlined,
    averageRate: 400,
    description: 'Leakage, taps, bathroom fittings',
    color: Color(0xFF2563EB),
  ),
  ServiceCategory(
    id: 'cleaner',
    name: 'Cleaner',
    icon: Icons.cleaning_services_outlined,
    averageRate: 350,
    description: 'Home, kitchen, move-in cleaning',
    color: Color(0xFF10B981),
  ),
  ServiceCategory(
    id: 'painter',
    name: 'Painter',
    icon: Icons.format_paint_outlined,
    averageRate: 700,
    description: 'Room paint, touchups, waterproofing',
    color: Color(0xFF8B5CF6),
  ),
  ServiceCategory(
    id: 'carpenter',
    name: 'Carpenter',
    icon: Icons.carpenter_outlined,
    averageRate: 550,
    description: 'Furniture repair, shelves, fittings',
    color: Color(0xFFB45309),
  ),
  ServiceCategory(
    id: 'labour',
    name: 'Daily Labour',
    icon: Icons.construction_outlined,
    averageRate: 650,
    description: 'Loading, shifting, site support',
    color: Color(0xFF475569),
  ),
];

final serviceCategoriesById = {
  for (final category in serviceCategories) category.id: category,
};

// Real worker supply should come from backend enrollment data.
// Keep this empty until workers are actually onboarded.
const enrolledWorkers = <WorkerProfile>[];
