/**
 ** Copyright (c) 2014 Illumina, Inc.
 **
 ** This file is part of Illumina's Enhanced Artificial Genome Engine (EAGLE),
 ** covered by the "BSD 2-Clause License" (see accompanying LICENSE file)
 **
 ** \description Top level code for allocateFragment
 **
 ** \author Lilian Janin
 **/

#include <math.h>
#include <vector>
#include <numeric>
#include <boost/assign.hpp>
#include <boost/bind.hpp>
#include <boost/filesystem.hpp>
#include <boost/foreach.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/shared_ptr.hpp>

#include "common/Exceptions.hh"
#include "common/Logger.hh"
#include "genome/Reference.hh"
#include "genome/SharedFastaReference.hh"
#include "model/IntervalGenerator.hh"
#include "model/Fragment.hh"
#include "model/FragmentLengthDist.hh"
#include "main/FragmentsAllocator.hh"

using namespace std;
using eagle::model::FragmentWithAllocationMetadata;


namespace eagle
{
namespace main
{


FragmentsAllocator::FragmentsAllocator( const FragmentsAllocatorOptions &options )
    : options_(options)
                                      //    , randomGen_( new boost::mt19937(options_.randomSeed) )
    , gcCoverageFit_( options_.gcCoverageFitFile, options_.sampleGenomeDir/*, randomGen_*/ )
{
}


void FragmentsAllocator::run()
{
    setRandomSeed();

    std::vector<unsigned long> contigLengths;
    std::vector<string> contigNames;
    unsigned long totalSize;

    genome::SharedFastaReference::init(  options_.sampleGenomeDir );
    contigNames = genome::SharedFastaReference::get()->allContigNames();

    if (options_.contigName != "")
    {
        // If a contig name is specified: only process this one
        for (unsigned int i=0; i<contigNames.size(); ++i)
        {
            if (contigNames[i] == options_.contigName)
            {
                contigLengths.push_back( genome::SharedFastaReference::get()->allContigLengths()[i] );
                break;
            }
        }
        if (contigLengths.empty())
        {
            // silently ignore any non-existing contig, as some might not exist due to translocations
            // (see Genome Mutator, for the fact that each allele contig has 2 end points, and only half of those end points are giving rise to a sample contig name)
            // if (boost::algorithn::ends_with( options_.contigName, "_rev" ))
            clog << "Ignoring attempt at allele " << options_.contigName << endl;
            return;
            //EAGLE_ERROR("contig " + options_.contigName + " not found");
        }
    }
    else
    {
        contigLengths = genome::SharedFastaReference::get()->allContigLengths();
    }

    BOOST_FOREACH( const unsigned long l, contigLengths )
    {
        clog << "chr length: " << l << endl;
    }

    totalSize = std::accumulate( contigLengths.begin(), contigLengths.end(), 0ul );
    clog << "total length: " << totalSize << endl;


    vector<unsigned int> tileReadCount( options_.tileCount, 0 );
    //  Get number of requested reads
    unsigned long readCount = static_cast<unsigned long>(totalSize * options_.coverageDepth / options_.basesPerCluster);
    clog << (boost::format("Starting the generation of %d fragments") % readCount).str() << endl;

    boost::shared_ptr<eagle::model::IntervalGenerator> randomInterval;
    boost::shared_ptr<eagle::model::MultiFragmentFilesReader> multiFragmentFilesReader;
    if (options_.mergeExistingFragments)
    {
        // Merge pre-calculated fragments
        // For this, the "interval generator" is actually a reader of existing fragments.* files
        try
        {
            multiFragmentFilesReader = boost::shared_ptr<eagle::model::MultiFragmentFilesReader>( new eagle::model::MultiFragmentFilesReader( contigLengths, contigNames, options_.outputDir, readCount ) );
        }
        catch (const eagle::common::EagleException &e)
        {
            if (boost::filesystem::exists( options_.outputDir / "fragments.done" ))
            {
                // If the "fragments.done" file already exists, we must be in the case of a directory generated by the mergeFragments tool
                // We can safely exit, as all the fragment files should already be present
                clog << "Fragments already present. Not regenerating." << endl;
                return;
            }
            else
            {
                throw;
            }
        }
    }
    else
    {
        if (options_.uniformCoverage)
        {
            double step = (double)options_.basesPerCluster / (double)options_.coverageDepth;
            randomInterval = boost::shared_ptr<eagle::model::IntervalGenerator>( new eagle::model::UniformIntervalGenerator( contigLengths, (unsigned int)options_.templateLengthStatistics.median, step, readCount) );
        }
        else
        {
            unsigned long extendedReadCount = static_cast<unsigned long>( ((double)readCount) / gcCoverageFit_.averageMultiplier() );
            clog << (boost::format("  ...increased to %d \"discardable\" fragments") % extendedReadCount).str() << endl;
            randomInterval = boost::shared_ptr<eagle::model::IntervalGenerator>( new eagle::model::RandomIntervalGeneratorUsingIntervalLengthDistribution( contigLengths, extendedReadCount, options_.templateLengthTableFile ) );
        }
    }


    std::ofstream out1     ( (options_.outputDir / "fragments.pos"      ).string().c_str(), ios::binary );
    std::ofstream out2     ( (options_.outputDir / "fragments.length"   ).string().c_str(), ios::binary );
    std::ofstream out3     ( (options_.outputDir / "fragments.tile"     ).string().c_str(), ios::binary );
    std::ofstream out4     ( (options_.outputDir / "fragments.stats"    ).string().c_str(), ios::binary );
    std::ofstream indexFile( (options_.outputDir / "fragments.pos.index").string().c_str(), ios::binary );
    std::ofstream shiftFile( (options_.outputDir / "fragments.pos.shift").string().c_str(), ios::binary );

    // Write index file header
    const unsigned long indexVersion = 1;
    const unsigned long indexInterval = 1000;
    indexFile.write( (char*)&indexVersion, sizeof(unsigned long));
    indexFile.write( (char*)&indexInterval, sizeof(unsigned long));
    unsigned long indexCount = 0;

//        for (unsigned long i=0; i<readCount; ++i)
    unsigned long i=0;
    while (++i) // always true
    {
        FragmentWithAllocationMetadata f = getNextFragment( randomInterval, multiFragmentFilesReader, i, readCount );
        if (!f.isValid())
        {
//                EAGLE_WARNING( (boost::format("Early termination of fragments generation at fragment %d") % i).str() );
            break;
        }

        // Output format:: binary 6 bytes per fragment
        static unsigned long lastPos = 0;
        static unsigned int shift = 0;
        unsigned long posDiff = static_cast<unsigned long>(f.startPos_) - lastPos;
/*
        if ( posDiff >= 65536 )
        {
            clog << "posDiff   =" << posDiff << endl;
            clog << "f.startPos_=" << f.startPos_ << endl;
//                clog << "nextPos   =" << nextInterval.first << endl;
            clog << "lastPos   =" << lastPos << endl;
        }
*/
        assert( f.fragmentLength_ < 65536 );
        assert( f.allocatedTile_ < 65536 );
        lastPos = f.startPos_;
        if (posDiff < 65535)
        {
            out1.write( (char*)&posDiff, 2);
        }
        else
        {
            const unsigned int const65535 = 65535;
            const unsigned int posDiffByte2 = posDiff >> 32;
            const unsigned int posDiffByte1 = ( posDiff >> 16 ) & 0xFFFF;
            const unsigned int posDiffByte0 = posDiff & 0xFFFF;
            assert( posDiffByte2 < 65536 );
            out1.write( (char*)&const65535 , 2);
            out1.write( (char*)&posDiffByte2, 2);
            out1.write( (char*)&posDiffByte1, 2);
            out1.write( (char*)&posDiffByte0, 2);
            shift += 3;
        }
        out2.write( (char*)&f.fragmentLength_, 2);
        out3.write( (char*)&f.allocatedTile_, 2);
        tileReadCount[f.allocatedTile_]++;
        assert( tileReadCount[f.allocatedTile_] != 0xFFFFFFFF && "Tile too large" );

        if (++indexCount == indexInterval)
        {
            indexFile.write( (char*)&lastPos, sizeof(unsigned long));
            shiftFile.write( (char*)&shift, sizeof(unsigned int));
            indexCount = 0;
        }
    }

    out4.write( (char*)&tileReadCount[0], tileReadCount.size() * sizeof(unsigned int) );

    // Count check
    unsigned long generatedCount = i-1;
    double coverageError = ((double)generatedCount/readCount) - 1;
    clog << (boost::format("Finished generation with %d fragments (=ideal%+.1f%%)") % generatedCount % (100*coverageError) ).str() << endl;
    if (fabs(coverageError) > options_.maxCoverageError)
    {
        EAGLE_WARNING( "Coverage error is higher than wanted!" );
    }
}


void FragmentsAllocator::setRandomSeed()
{
    // Now that this Fragments Allocator is called for each contig, we need a way to have different (but reproducable) random seeds for each of them.
    // We use the contig name to alter the input seed.
    unsigned int randomSeed = options_.randomSeed;
    BOOST_FOREACH( const char c, options_.contigName )
    {
        randomSeed *= c;
        ++randomSeed; // to generate different results in case the initial seed was 0
    }
    srand( randomSeed );
}


FragmentWithAllocationMetadata FragmentsAllocator::getNextFragment( boost::shared_ptr<eagle::model::IntervalGenerator>& randomInterval,
                                                                    boost::shared_ptr<eagle::model::MultiFragmentFilesReader>& multiFragmentFilesReader,
                                                                    const unsigned long fragmentNum,
                                                                    const unsigned long fragmentCount)
{
    if (!options_.mergeExistingFragments)
    {
        while (1) // repeat until a valid fragment is generated, then return
        {
            pair<unsigned long,unsigned int> nextInterval = randomInterval->getNext();
            if (nextInterval.second == 0)
            {
                return FragmentWithAllocationMetadata();
            }
            FragmentWithAllocationMetadata f( nextInterval );

            if (gcCoverageFit_.needsDiscarding( f ))
            {
//                clog << "Discarding" << endl;
                continue; // discard fragment and generate next one
            }

            switch (options_.tileAllocationMethod)
            {
            case eagle::main::FragmentsAllocatorOptions::TILE_ALLOCATION_RANDOM:
                f.allocateRandomTile(options_.tileCount);
                break;
            case eagle::main::FragmentsAllocatorOptions::TILE_ALLOCATION_SEQUENCE:
                f.allocateTileInSequence(options_.tileCount, fragmentNum, fragmentCount);
                break;
            case eagle::main::FragmentsAllocatorOptions::TILE_ALLOCATION_INTERLEAVED:
                f.allocateInterleavedTile(options_.tileCount);
                break;
            default:
                EAGLE_ERROR("tile allocation method not implemented");
            }
            return f;
        }
    }
    else
    {
        return multiFragmentFilesReader->getNext();
    }
}


} // namespace main
} // namespace eagle