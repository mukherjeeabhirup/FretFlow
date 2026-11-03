(function (root) {
    'use strict';

    const configured = new WeakSet();
    const supportedVersion = '1.8.4';
    const numberBandID = 'fretflow-measure-number';

    function configure(at) {
        if (!at || at.meta?.version !== supportedVersion) {
            throw new Error('The notation spacing adapter requires alphaTab ' + supportedVersion + '.');
        }
        if (configured.has(at)) return {version: supportedVersion, measureNumberBand: true};

        // alphaTab 1.8.4 shares effect lanes using beat times, without checking
        // text widths. A section label can therefore collide with a palm-mute
        // label on the following beat. Its native measure numbers also sit at
        // a fixed staff offset, inside ties that cross the preceding barline.
        // Keep both in dedicated effect lanes so alphaTab itself reserves their
        // space, including across partial rendering, wrapping, and zoom changes.
        // These renderer extension points are internal: keep the version guard
        // and browser regression checks when upgrading the bundled renderer.
        const factories = at.Environment?.defaultRenderers;
        const tabFactory = Array.isArray(factories) && factories.find(factory => factory.staffId === 'tab');
        const markerBands = Array.isArray(factories)
            ? factories.flatMap(factory => factory.effectBands || [])
                .filter(band => band.effect?.notationElement === at.NotationElement.EffectMarker)
            : [];
        const marker = markerBands[0]?.effect;
        if (!tabFactory || typeof tabFactory.create !== 'function' || !Array.isArray(tabFactory.effectBands)
            || !marker || typeof marker.createNewGlyph !== 'function' || marker.sizingMode !== 0
            || !at.model?.BarNumberDisplay || typeof at.RenderingResources !== 'function') {
            throw new Error('The bundled notation renderer has an unsupported effect layout API.');
        }

        // Obtain alphaTab's ordinary text glyph through its marker factory,
        // rather than copying drawing code or depending on minified class names.
        const probe = marker.createNewGlyph({resources: new at.RenderingResources()}, {
            voice: {bar: {masterBar: {section: {marker: '', text: ''}}}}
        });
        const TextGlyph = probe?.constructor;
        if (typeof TextGlyph !== 'function' || typeof probe.doLayout !== 'function'
            || typeof probe.paint !== 'function') {
            throw new Error('The bundled notation renderer has an unsupported text glyph API.');
        }

        const display = at.model.BarNumberDisplay;
        function numberDisplay(bar) {
            return bar.barNumberDisplay ?? bar.staff.track.score.stylesheet.barNumberDisplay;
        }

        class MeasureNumberEffect extends marker.constructor {
            get effectId() { return numberBandID; }
            get notationElement() { return at.NotationElement.BarNumber; }
            get canShareBand() { return false; }
            shouldCreateGlyph(renderer, beat) {
                return beat.voice.index === 0 && beat.index === 0
                    && numberDisplay(beat.voice.bar) !== display.Hide;
            }
            createNewGlyph(renderer, beat) {
                const bar = beat.voice.bar;
                const font = renderer.resources.elementFonts.get(at.NotationElement.BarNumber);
                const glyph = new TextGlyph(0, 0, String(bar.index + 1), font);
                glyph.colorOverride = renderer.resources.barNumberColor;
                const layout = glyph.doLayout;
                glyph.doLayout = function () {
                    layout.call(this);
                    this.height = Math.max(this.height, font.size);
                };
                const paint = glyph.paint;
                glyph.paint = function (x, y, canvas) {
                    // FirstOfSystem must be checked after line wrapping settles.
                    // Candidate glyphs still reserve the lane during layout.
                    if (!renderer.staff.isFirstInSystem
                        || (numberDisplay(bar) === display.FirstOfSystem && !renderer.isFirstOfStaff)) return;
                    canvas.beginGroup(numberBandID + '-' + (bar.index + 1));
                    try { paint.call(this, x, y, canvas); }
                    finally { canvas.endGroup(); }
                };
                return glyph;
            }
        }

        function outerChordNote(note) {
            return note.beat.notes.reduce((outer, candidate) =>
                candidate.isVisible && candidate.string > outer.string ? candidate : outer, note);
        }

        function placeChordEffectSlur(tie) {
            // A legato-slide/hammer-on slur on an inner string can otherwise put
            // its curve and label through the chord's higher frets and ties.
            // Move only the upward effect slur around the chord's outside edge.
            // The diagonal slide, ordinary ties, and downward slur stay attached
            // to their original notes; no musical data is rewritten.
            if (!tie.slurEffectId?.startsWith('tab.slur.effect.') || !tie.startNote || !tie.endNote) return;
            if (typeof tie.calculateStartY !== 'function' || typeof tie.caclculateEndY !== 'function'
                || typeof tie.lookupStartBeatRenderer !== 'function'
                || typeof tie.lookupEndBeatRenderer !== 'function' || typeof tie.paint !== 'function') {
                throw new Error('The bundled notation renderer has an unsupported chord-slur API.');
            }
            const up = at.rendering.BeamDirection.Up;
            function needsOuterAnchor() {
                return tie.tieDirection === up
                    && (outerChordNote(tie.startNote) !== tie.startNote
                        || outerChordNote(tie.endNote) !== tie.endNote);
            }
            function anchorY(note, renderer, originalY) {
                if (!renderer || !needsOuterAnchor()) return originalY;
                const outer = outerChordNote(note);
                // NoteYPosition.Top is 1 in the pinned renderer. Use its actual
                // fret glyph bounds, then clear any ordinary tie on that note
                // using the same engraving metric as alphaTab's own tie curve.
                let y = renderer.y + renderer.getNoteY(outer, 1);
                if (outer.isTieOrigin || outer.isTieDestination) y -= renderer.smuflMetrics.tieHeight;
                return Math.min(originalY, y);
            }
            const startY = tie.calculateStartY;
            tie.calculateStartY = function () {
                return anchorY(this.startNote, this.lookupStartBeatRenderer(), startY.call(this));
            };
            const endY = tie.caclculateEndY;
            tie.caclculateEndY = function () {
                return anchorY(this.endNote, this.lookupEndBeatRenderer(), endY.call(this));
            };
            // doLayout consumes the adjusted anchors before calculating slur
            // bounds and label positions; native overflow reservation therefore
            // includes the entire moved curve and its text automatically.
            const paint = tie.paint;
            tie.paint = function (x, y, canvas) {
                if (!needsOuterAnchor()) return paint.call(this, x, y, canvas);
                const beat = this.startNote.beat;
                canvas.beginGroup('fretflow-chord-effect-slur-' + (beat.voice.bar.index + 1) + '-' + beat.index);
                try { paint.call(this, x, y, canvas); }
                finally { canvas.endGroup(); }
            };
        }

        const createTabRenderer = tabFactory.create;
        tabFactory.create = function (...args) {
            const renderer = createTabRenderer.apply(this, args);
            if (typeof renderer.shouldCreateBarNumber !== 'function' || typeof renderer.registerTie !== 'function') {
                throw new Error('The bundled notation renderer has an unsupported measure-number API.');
            }
            renderer.shouldCreateBarNumber = () => false;
            const registerTie = renderer.registerTie;
            renderer.registerTie = function (tie) {
                placeChordEffectSlur(tie);
                return registerTie.call(this, tie);
            };
            return renderer;
        };
        // Mode 0 is OwnedTop in the pinned renderer. It keeps this annotation
        // with the tablature staff, including when other stave profiles exist.
        tabFactory.effectBands.push({effect: new MeasureNumberEffect(), mode: 0, order: 2000});
        for (const band of markerBands) {
            Object.defineProperty(band.effect, 'canShareBand', {value: false, configurable: true});
        }
        configured.add(at);
        return {version: supportedVersion, measureNumberBand: true};
    }

    root.FretFlowNotationLayout = Object.freeze({configure});
})(typeof window !== 'undefined' ? window : globalThis);
