// Ported from Beacon-Web's map marker artwork. Rasterized for MapLibre Native.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

const markerSvgs = <String, String>{
  'glitch-companion-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="client observer master">
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#3b82f6" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#3b82f6" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#3b82f6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="24" y="22" width="16" height="30" rx="4"></rect>
    <path d="M28.5 22 L23 11"></path>
    <circle cx="23" cy="11" r="1.8" fill="#3b82f6" stroke="none"></circle>
    <line x1="29" y1="29" x2="35" y2="29"></line>
    <line x1="29" y1="33" x2="35" y2="33"></line>
    <rect x="28" y="40" width="8" height="7" rx="1.6"></rect>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'glitch-companion': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="client master">
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#3b82f6" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#3b82f6" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#3b82f6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="24" y="22" width="16" height="30" rx="4"></rect>
    <path d="M28.5 22 L23 11"></path>
    <circle cx="23" cy="11" r="1.8" fill="#3b82f6" stroke="none"></circle>
    <line x1="29" y1="29" x2="35" y2="29"></line>
    <line x1="29" y1="33" x2="35" y2="33"></line>
    <rect x="28" y="40" width="8" height="7" rx="1.6"></rect>
  </g>
</svg>''',
  'glitch-repeater-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="repeater observer master">
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#a78bfa" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#a78bfa" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#a78bfa" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#a78bfa" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <line x1="32" y1="26" x2="32" y2="45"></line>
    <path d="M32 45 L25 51 M32 45 L39 51"></path>
    <circle cx="32" cy="23" r="2.6" fill="#a78bfa" stroke="none"></circle>
    <path d="M25.5 17.5 A 10 10 0 0 0 25.5 30.5"></path>
    <path d="M20 13.5 A 15 15 0 0 0 20 34.5"></path>
    <path d="M38.5 17.5 A 10 10 0 0 1 38.5 30.5"></path>
    <path d="M44 13.5 A 15 15 0 0 1 44 34.5"></path>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'glitch-repeater': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="repeater master">
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#a78bfa" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#a78bfa" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#a78bfa" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#a78bfa" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <line x1="32" y1="26" x2="32" y2="45"></line>
    <path d="M32 45 L25 51 M32 45 L39 51"></path>
    <circle cx="32" cy="23" r="2.6" fill="#a78bfa" stroke="none"></circle>
    <path d="M25.5 17.5 A 10 10 0 0 0 25.5 30.5"></path>
    <path d="M20 13.5 A 15 15 0 0 0 20 34.5"></path>
    <path d="M38.5 17.5 A 10 10 0 0 1 38.5 30.5"></path>
    <path d="M44 13.5 A 15 15 0 0 1 44 34.5"></path>
  </g>
</svg>''',
  'glitch-room_server-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="server observer master">
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#22c55e" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#22c55e" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#22c55e" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="18" y="15" width="28" height="34" rx="3.5"></rect>
    <line x1="18" y1="26.3" x2="46" y2="26.3"></line>
    <line x1="18" y1="37.7" x2="46" y2="37.7"></line>
    <circle cx="24" cy="20.6" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="32" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="43.4" r="1.9" fill="#22c55e" stroke="none"></circle>
    <line x1="33" y1="20.6" x2="41" y2="20.6"></line>
    <line x1="33" y1="32" x2="41" y2="32"></line>
    <line x1="33" y1="43.4" x2="41" y2="43.4"></line>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'glitch-room_server': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="server master">
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#22c55e" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#22c55e" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#22c55e" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="18" y="15" width="28" height="34" rx="3.5"></rect>
    <line x1="18" y1="26.3" x2="46" y2="26.3"></line>
    <line x1="18" y1="37.7" x2="46" y2="37.7"></line>
    <circle cx="24" cy="20.6" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="32" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="43.4" r="1.9" fill="#22c55e" stroke="none"></circle>
    <line x1="33" y1="20.6" x2="41" y2="20.6"></line>
    <line x1="33" y1="32" x2="41" y2="32"></line>
    <line x1="33" y1="43.4" x2="41" y2="43.4"></line>
  </g>
</svg>''',
  'glitch-sensor-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="sensor observer master">
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#eab308" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#eab308" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#eab308" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#eab308" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#eab308" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="32" cy="32" r="13.5"></circle>
    <circle cx="32" cy="32" r="6.5"></circle>
    <circle cx="32" cy="32" r="2.1" fill="#eab308" stroke="none"></circle>
    <line x1="32" y1="13" x2="32" y2="18.5"></line>
    <line x1="32" y1="45.5" x2="32" y2="51"></line>
    <line x1="13" y1="32" x2="18.5" y2="32"></line>
    <line x1="45.5" y1="32" x2="51" y2="32"></line>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'glitch-sensor': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="sensor master">
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#eab308" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <path d="M32 3 A29 29 0 0 1 61 32 A29 29 0 0 1 32 61 A29 29 0 0 1 3 32 A29 29 0 0 1 24 4 Z" fill="#eab308" fill-opacity="0.16"></path>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#eab308" stroke-width="2"></circle>
  <path d="M44 6 L58 20" stroke="#eab308" stroke-width="2" stroke-linecap="round" opacity="0.8"></path>
  <g fill="none" stroke="#eab308" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="32" cy="32" r="13.5"></circle>
    <circle cx="32" cy="32" r="6.5"></circle>
    <circle cx="32" cy="32" r="2.1" fill="#eab308" stroke="none"></circle>
    <line x1="32" y1="13" x2="32" y2="18.5"></line>
    <line x1="32" y1="45.5" x2="32" y2="51"></line>
    <line x1="13" y1="32" x2="18.5" y2="32"></line>
    <line x1="45.5" y1="32" x2="51" y2="32"></line>
  </g>
</svg>''',
  'wireframe-companion-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="client observer master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#3b82f6" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#3b82f6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="24" y="22" width="16" height="30" rx="4"></rect>
    <path d="M28.5 22 L23 11"></path>
    <circle cx="23" cy="11" r="1.8" fill="#3b82f6" stroke="none"></circle>
    <line x1="29" y1="29" x2="35" y2="29"></line>
    <line x1="29" y1="33" x2="35" y2="33"></line>
    <rect x="28" y="40" width="8" height="7" rx="1.6"></rect>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'wireframe-companion': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="client master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#3b82f6" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#3b82f6" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="24" y="22" width="16" height="30" rx="4"></rect>
    <path d="M28.5 22 L23 11"></path>
    <circle cx="23" cy="11" r="1.8" fill="#3b82f6" stroke="none"></circle>
    <line x1="29" y1="29" x2="35" y2="29"></line>
    <line x1="29" y1="33" x2="35" y2="33"></line>
    <rect x="28" y="40" width="8" height="7" rx="1.6"></rect>
  </g>
</svg>''',
  'wireframe-repeater-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="repeater observer master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#a78bfa" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <line x1="32" y1="26" x2="32" y2="45"></line>
    <path d="M32 45 L25 51 M32 45 L39 51"></path>
    <circle cx="32" cy="23" r="2.6" fill="#a78bfa" stroke="none"></circle>
    <path d="M25.5 17.5 A 10 10 0 0 0 25.5 30.5"></path>
    <path d="M20 13.5 A 15 15 0 0 0 20 34.5"></path>
    <path d="M38.5 17.5 A 10 10 0 0 1 38.5 30.5"></path>
    <path d="M44 13.5 A 15 15 0 0 1 44 34.5"></path>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'wireframe-repeater': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="repeater master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#a78bfa" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#a78bfa" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <line x1="32" y1="26" x2="32" y2="45"></line>
    <path d="M32 45 L25 51 M32 45 L39 51"></path>
    <circle cx="32" cy="23" r="2.6" fill="#a78bfa" stroke="none"></circle>
    <path d="M25.5 17.5 A 10 10 0 0 0 25.5 30.5"></path>
    <path d="M20 13.5 A 15 15 0 0 0 20 34.5"></path>
    <path d="M38.5 17.5 A 10 10 0 0 1 38.5 30.5"></path>
    <path d="M44 13.5 A 15 15 0 0 1 44 34.5"></path>
  </g>
</svg>''',
  'wireframe-room_server-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="server observer master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#22c55e" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="18" y="15" width="28" height="34" rx="3.5"></rect>
    <line x1="18" y1="26.3" x2="46" y2="26.3"></line>
    <line x1="18" y1="37.7" x2="46" y2="37.7"></line>
    <circle cx="24" cy="20.6" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="32" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="43.4" r="1.9" fill="#22c55e" stroke="none"></circle>
    <line x1="33" y1="20.6" x2="41" y2="20.6"></line>
    <line x1="33" y1="32" x2="41" y2="32"></line>
    <line x1="33" y1="43.4" x2="41" y2="43.4"></line>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'wireframe-room_server': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="server master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#22c55e" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="18" y="15" width="28" height="34" rx="3.5"></rect>
    <line x1="18" y1="26.3" x2="46" y2="26.3"></line>
    <line x1="18" y1="37.7" x2="46" y2="37.7"></line>
    <circle cx="24" cy="20.6" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="32" r="1.9" fill="#22c55e" stroke="none"></circle>
    <circle cx="24" cy="43.4" r="1.9" fill="#22c55e" stroke="none"></circle>
    <line x1="33" y1="20.6" x2="41" y2="20.6"></line>
    <line x1="33" y1="32" x2="41" y2="32"></line>
    <line x1="33" y1="43.4" x2="41" y2="43.4"></line>
  </g>
</svg>''',
  'wireframe-sensor-observer': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="sensor observer master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#eab308" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#eab308" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#eab308" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="32" cy="32" r="13.5"></circle>
    <circle cx="32" cy="32" r="6.5"></circle>
    <circle cx="32" cy="32" r="2.1" fill="#eab308" stroke="none"></circle>
    <line x1="32" y1="13" x2="32" y2="18.5"></line>
    <line x1="32" y1="45.5" x2="32" y2="51"></line>
    <line x1="13" y1="32" x2="18.5" y2="32"></line>
    <line x1="45.5" y1="32" x2="51" y2="32"></line>
  </g>
  <g>
    <circle cx="50.5" cy="50.5" r="14.4" fill="#0c1018"></circle>
    <circle cx="50.5" cy="50.5" r="12" fill="#0c1018" stroke="#c79bff" stroke-width="2"></circle>
    <path d="M 44.2 50.5 C 47.4 46, 53.6 46, 56.8 50.5 C 53.6 55, 47.4 55, 44.2 50.5 Z" fill="none" stroke="#c79bff" stroke-width="1.9" stroke-linejoin="round"></path>
    <circle cx="50.5" cy="50.5" r="2.2" fill="#c79bff"></circle>
  </g>
</svg>''',
  'wireframe-sensor': r'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none" role="img" aria-label="sensor master"><circle cx="32" cy="32" r="29" fill="#ffffff" fill-opacity="0.95"/>
  <g transform="translate(32,32)">
    <circle cx="0" cy="0" r="20" fill="none" stroke="#eab308" stroke-width="2" opacity="0">
      
      
    </circle>
  </g>
  <circle cx="32" cy="32" r="29" fill="none" stroke="#eab308" stroke-width="2" opacity="0.9"></circle>
  <g fill="none" stroke="#eab308" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="32" cy="32" r="13.5"></circle>
    <circle cx="32" cy="32" r="6.5"></circle>
    <circle cx="32" cy="32" r="2.1" fill="#eab308" stroke="none"></circle>
    <line x1="32" y1="13" x2="32" y2="18.5"></line>
    <line x1="32" y1="45.5" x2="32" y2="51"></line>
    <line x1="13" y1="32" x2="18.5" y2="32"></line>
    <line x1="45.5" y1="32" x2="51" y2="32"></line>
  </g>
</svg>''',
  'cluster-0': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/></svg>''',
  'cluster-1': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/></svg>''',
  'cluster-2': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/></svg>''',
  'cluster-3': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/></svg>''',
  'cluster-4': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.16"/></svg>''',
  'cluster-5': r'''<svg xmlns="http://www.w3.org/2000/svg" width="88" height="88" viewBox="-8 -8 88 88"><polygon points="36,10 58.5,23 58.5,49 36,62 13.5,49 13.5,23" fill="#0c1018" fill-opacity="0.92" stroke="#3b82f6" stroke-width="2.25" stroke-linejoin="round"/><line x1="36" y1="3" x2="36" y2="5.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="7.4" x2="51.3" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="19.5" x2="62.4" y2="20.8" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="69" y1="36" x2="66.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="64.6" y1="52.5" x2="62.4" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="52.5" y1="64.6" x2="51.3" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="36" y1="69" x2="36" y2="66.5" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="19.5" y1="64.6" x2="20.8" y2="62.4" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="7.4" y1="52.5" x2="9.6" y2="51.3" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="3" y1="36" x2="5.5" y2="36" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="7.4" y1="19.5" x2="9.6" y2="20.7" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/><line x1="19.5" y1="7.4" x2="20.7" y2="9.6" stroke="#3b82f6" stroke-width="2.4" stroke-linecap="round" opacity="0.95"/></svg>''',
};
const nodeColors = {
  'companion': '#3b82f6',
  'repeater': '#a78bfa',
  'room_server': '#22c55e',
  'sensor': '#eab308',
};

final _glyph = RegExp(
  r'<g fill="none" stroke="#[0-9a-f]{6}" stroke-width="3".*?</g>',
  dotAll: true,
);

// The ring is baked in so it stacks with its own marker.
String liveMarkerSvg(String type) {
  final color = nodeColors[type]!;
  final glyph = _glyph
      .firstMatch(markerSvgs['glitch-$type']!)![0]!
      .replaceAll(color, '#ffffff');
  return '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 88 88" width="88" height="88" fill="none">
  <defs><radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="32" cy="32" r="44"><stop offset="0.6" stop-color="$color" stop-opacity="0.5"/><stop offset="1" stop-color="$color" stop-opacity="0"/></radialGradient></defs>
  <circle cx="32" cy="32" r="44" fill="url(#glow)"/>
  <circle cx="32" cy="32" r="29" fill="$color" stroke="#ffffff" stroke-opacity="0.5" stroke-width="2.5"/>
  $glyph
  <circle cx="32" cy="32" r="39" stroke="#ff6b35" stroke-width="6"/>
</svg>''';
}

final _markerCache = <String, Future<Uint8List>>{};
Future<Uint8List> markerImage(String key, {double scale = 1}) =>
    _markerCache.putIfAbsent('$key@$scale', () async {
      final svg = key.startsWith('live-')
          ? liveMarkerSvg(key.substring(5))
          : markerSvgs[key]!;
      final picture = await vg.loadPicture(SvgStringLoader(svg), null);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..scale(scale);
      canvas.drawPicture(picture.picture);
      final scaled = recorder.endRecording();
      final image = await scaled.toImage(
        (88 * scale).round(),
        (88 * scale).round(),
      );
      scaled.dispose();
      picture.picture.dispose();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes!.buffer.asUint8List();
    });
