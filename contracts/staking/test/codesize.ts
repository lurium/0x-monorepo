import { chaiSetup, constants, getCodesizeFromArtifact } from '@0x/contracts-test-utils';
import * as chai from 'chai';

chaiSetup.configure();
const expect = chai.expect;

import { artifacts } from '../src';

describe.skip('Contract Size Checks', () => {
    describe('Staking', () => {
        it('should have a codesize less than the maximum', async () => {
            const actualSize = getCodesizeFromArtifact(artifacts.Staking);
            expect(actualSize).to.be.lt(constants.MAX_CODE_SIZE);
        });
    });
    describe('StakingProxy', () => {
        it('should have a codesize less than the maximum', async () => {
            const actualSize = getCodesizeFromArtifact(artifacts.StakingProxy);
            expect(actualSize).to.be.lt(constants.MAX_CODE_SIZE);
        });
    });
});