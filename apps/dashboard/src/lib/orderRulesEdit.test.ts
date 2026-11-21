import { describe, expect, it } from 'vitest';
import { nextPosition, paramsFor, routingParams, slugCode, tagParams, validateRouting, validateTag, valueFromParams, type RoutingForm, type TagForm } from './orderRulesEdit';

const empty = { n: '', field: '', tag: '' };
const routing = (o: Partial<RoutingForm> = {}): RoutingForm => ({ name: 'Big orders', kind: 'decorations_over', value: { ...empty, n: '20' }, scope: 'third_party', producerId: 'p1', position: '10', active: true, reason: 'Daniel asked for this', ...o });
const tag = (o: Partial<TagForm> = {}): TagForm => ({ tagCode: 'person_packing', tagLabel: '', isNew: false, name: 'Names', kind: 'custom_field_filled', value: { ...empty, field: 'Uniform For' }, active: true, reason: 'Pack by person', ...o });

describe('rule settings', () => {
  it('turns what was typed into the settings the database stores', () => {
    expect(paramsFor('decorations_over', { ...empty, n: ' 20 ' })).toEqual({ n: 20 });
    expect(paramsFor('units_over', { ...empty, n: '0' })).toEqual({ n: 0 });
    expect(paramsFor('custom_field_filled', { ...empty, field: ' Uniform For ' })).toEqual({ field: 'Uniform For' });
    expect(paramsFor('tag_present', { ...empty, tag: 'person_packing' })).toEqual({ tag: 'person_packing' });
  });
  it('refuses values that cannot be used', () => {
    expect(paramsFor('decorations_over', { ...empty, n: 'lots' })).toBeNull(); expect(paramsFor('decorations_over', { ...empty, n: '-3' })).toBeNull(); expect(paramsFor('decorations_over', { ...empty, n: '1.5' })).toBeNull();
    expect(paramsFor('custom_field_filled', empty)).toBeNull(); expect(paramsFor('tag_present', empty)).toBeNull(); expect(paramsFor('nope', { ...empty, n: '1' })).toBeNull();
  });
  it('fills the form from an existing rule', () => {
    expect(valueFromParams('decorations_over', { n: 20 })).toEqual({ n: '20', field: '', tag: '' });
    expect(valueFromParams('custom_field_filled', { field: 'Uniform For' }).field).toBe('Uniform For'); expect(valueFromParams('x', null)).toEqual(empty);
  });
  it('makes a tag code from its label', () => {
    expect(slugCode('Needs folding')).toBe('needs_folding'); expect(slugCode('  Gift wrap!! ')).toBe('gift_wrap'); expect(slugCode('3 boxes')).toBe('t_3_boxes'); expect(slugCode('???')).toBe('');
  });
  it('puts a new rule after the others', () => { expect(nextPosition([])).toBe(10); expect(nextPosition([{ position: 10 }])).toBe(20); expect(nextPosition([{ position: 5 }, { position: 14 }])).toBe(20); });
});

describe('routing rule form', () => {
  it('accepts a complete rule and builds what is sent', () => {
    expect(validateRouting(routing())).toBeNull();
    expect(routingParams(routing(), null)).toEqual({ id: null, name: 'Big orders', kind: 'decorations_over', params: { n: 20 }, scope: 'third_party', producer_id: 'p1', position: 10, active: true, reason: 'Daniel asked for this' });
  });
  it('says what is missing in plain words', () => {
    expect(validateRouting(routing({ name: ' ' }))).toMatch(/name/); expect(validateRouting(routing({ value: empty }))).toMatch(/whole number/); expect(validateRouting(routing({ kind: 'tag_present', value: empty }))).toMatch(/tag/);
    expect(validateRouting(routing({ position: 'first' }))).toMatch(/position/); expect(validateRouting(routing({ reason: 'x' }))).toMatch(/reason/);
  });
  it('does not allow an in-house rule to name a producer, and drops a producer it does not need', () => {
    expect(validateRouting(routing({ scope: 'in_house' }))).toMatch(/no producer/);
    expect(routingParams(routing({ scope: 'in_house', producerId: '' }), 'r1')).toMatchObject({ id: 'r1', scope: 'in_house', producer_id: null });
    expect(routingParams(routing({ producerId: '' }), null).producer_id).toBeNull();
  });
});

describe('tag rule form', () => {
  it('accepts an existing tag with a custom field', () => { expect(validateTag(tag())).toBeNull(); expect(tagParams(tag(), 't1')).toEqual({ id: 't1', tag_code: 'person_packing', tag_label: null, name: 'Names', kind: 'custom_field_filled', params: { field: 'Uniform For' }, active: true, reason: 'Pack by person' }); });
  it('a new tag needs a label and gets a code from it', () => {
    expect(validateTag(tag({ isNew: true, tagLabel: '' }))).toMatch(/label/); expect(validateTag(tag({ isNew: true, tagLabel: '???' }))).toMatch(/letters/);
    expect(tagParams(tag({ isNew: true, tagLabel: 'Needs folding', kind: 'units_over', value: { ...empty, n: '10' } }), null)).toMatchObject({ tag_code: 'needs_folding', tag_label: 'Needs folding', kind: 'units_over', params: { n: 10 } });
  });
  it('needs a reason, a name and usable settings', () => { expect(validateTag(tag({ reason: '' }))).toMatch(/reason/); expect(validateTag(tag({ name: '' }))).toMatch(/name/); expect(validateTag(tag({ value: empty }))).toMatch(/custom field/); expect(validateTag(tag({ tagCode: '' }))).toMatch(/Choose a tag/); });
});
